#include <libusb.h>
#include <CommonCrypto/CommonDigest.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MIJIA_VID 0x302c
#define MIJIA_PID 0x3008
#define COMMAND_INTERFACE 2
#define DATA_INTERFACE 2
#define COMMAND_OUT 0x06
#define COMMAND_IN 0x86
#define DATA_OUT 0x06
#define DATA_IN 0x86
#define USB_TIMEOUT_MS 10000
#define USB_RESPONSE_TIMEOUT_MS 3000
#define DATA_CHUNK_SIZE 10215
#define USB_WRITE_SIZE 1024

typedef struct {
    libusb_context *context;
    libusb_device_handle *handle;
    int command_claimed;
    int data_claimed;
} Printer;

static void print_error_json(const char *message) {
    fputs("{\"ok\":false,\"error\":\"", stdout);
    for (const unsigned char *p = (const unsigned char *)message; *p; ++p) {
        if (*p == '\\' || *p == '\"') {
            fputc('\\', stdout);
            fputc(*p, stdout);
        } else if (*p >= 0x20) {
            fputc(*p, stdout);
        }
    }
    fputs("\"}\n", stdout);
}

static int fail_libusb(const char *operation, int code) {
    char message[512];
    snprintf(message, sizeof(message), "%s: %s", operation, libusb_error_name(code));
    print_error_json(message);
    return 1;
}

static void close_printer(Printer *printer) {
    if (printer->handle != NULL) {
        if (printer->data_claimed) {
            libusb_release_interface(printer->handle, DATA_INTERFACE);
        }
        if (printer->command_claimed) {
            libusb_release_interface(printer->handle, COMMAND_INTERFACE);
        }
        libusb_close(printer->handle);
    }
    if (printer->context != NULL) {
        libusb_exit(printer->context);
    }
    memset(printer, 0, sizeof(*printer));
}

static int open_printer(Printer *printer, int with_data) {
    memset(printer, 0, sizeof(*printer));
    int result = libusb_init(&printer->context);
    if (result != LIBUSB_SUCCESS) {
        return fail_libusb("USB initialization failed", result);
    }
    printer->handle = libusb_open_device_with_vid_pid(printer->context, MIJIA_VID, MIJIA_PID);
    if (printer->handle == NULL) {
        print_error_json("未找到米家桌面照片打印机 2，请检查 Type-C 连接和电源");
        close_printer(printer);
        return 1;
    }
    (void)libusb_set_auto_detach_kernel_driver(printer->handle, 1);
    result = libusb_claim_interface(printer->handle, COMMAND_INTERFACE);
    if (result != LIBUSB_SUCCESS) {
        close_printer(printer);
        return fail_libusb("Cannot claim the printer command interface", result);
    }
    printer->command_claimed = 1;
    if (with_data && DATA_INTERFACE != COMMAND_INTERFACE) {
        result = libusb_claim_interface(printer->handle, DATA_INTERFACE);
        if (result != LIBUSB_SUCCESS) {
            close_printer(printer);
            return fail_libusb("Cannot claim the printer data interface", result);
        }
        printer->data_claimed = 1;
    }
    return 0;
}

static int bulk_write_all(libusb_device_handle *handle, unsigned char endpoint,
                          const unsigned char *bytes, size_t length, int max_transfer) {
    size_t offset = 0;
    while (offset < length) {
        int request = (int)(length - offset);
        if (request > max_transfer) {
            request = max_transfer;
        }
        int transferred = 0;
        int result = libusb_bulk_transfer(handle, endpoint, (unsigned char *)bytes + offset,
                                          request, &transferred, USB_TIMEOUT_MS);
        if (result != LIBUSB_SUCCESS) {
            return result;
        }
        if (transferred <= 0) {
            return LIBUSB_ERROR_IO;
        }
        offset += (size_t)transferred;
    }
    return LIBUSB_SUCCESS;
}

static int send_json_command(Printer *printer, const char *json, int request_id,
                             char *response, size_t response_capacity) {
    static const char header[] = "cmd json\n";
    size_t json_length = strlen(json);
    size_t packet_length = sizeof(header) - 1 + json_length;
    unsigned char *packet = malloc(packet_length);
    if (packet == NULL) {
        return LIBUSB_ERROR_NO_MEM;
    }
    memcpy(packet, header, sizeof(header) - 1);
    memcpy(packet + sizeof(header) - 1, json, json_length);
    int result = bulk_write_all(printer->handle, COMMAND_OUT, packet, packet_length, 65536);
    free(packet);
    if (result != LIBUSB_SUCCESS) {
        return result;
    }

    char compact_id_marker[40];
    char spaced_id_marker[40];
    snprintf(compact_id_marker, sizeof(compact_id_marker), "\"id\":%d", request_id);
    snprintf(spaced_id_marker, sizeof(spaced_id_marker), "\"id\": %d", request_id);
    for (int attempt = 0; attempt < 12; ++attempt) {
        int transferred = 0;
        result = libusb_bulk_transfer(printer->handle, COMMAND_IN, (unsigned char *)response,
                                      (int)response_capacity - 1, &transferred,
                                      USB_RESPONSE_TIMEOUT_MS);
        if (result != LIBUSB_SUCCESS) {
            return result;
        }
        response[transferred] = '\0';
        char *json_start = response;
        if (strncmp(response, header, sizeof(header) - 1) == 0) {
            json_start += sizeof(header) - 1;
        }
        // Interface 2 multiplexes JSON replies, asynchronous events and data
        // acknowledgements. Only the reply carrying our request id belongs to
        // this command; accepting any non-event packet can consume a stale
        // response and shift the entire request/reply stream.
        if (strstr(json_start, compact_id_marker) != NULL ||
            strstr(json_start, spaced_id_marker) != NULL) {
            if (json_start != response) {
                memmove(response, json_start, strlen(json_start) + 1);
            }
            return LIBUSB_SUCCESS;
        }
    }
    return LIBUSB_ERROR_TIMEOUT;
}

static int query_status(Printer *printer, char *status, size_t status_size,
                        char *device_info, size_t info_size) {
    const char *status_json =
        "{\"method\":\"get-prop\",\"params\":[\"printer-state\",\"printer-sub-state\","
        "\"printer-state-alerts\"],\"id\":1001}";
    int result = send_json_command(printer, status_json, 1001, status, status_size);
    if (result != LIBUSB_SUCCESS) {
        return result;
    }
    const char *info_json =
        "{\"method\":\"get-prop\",\"params\":[\"device-info\"],\"id\":1002}";
    return send_json_command(printer, info_json, 1002, device_info, info_size);
}

static long parse_job_id(const char *response) {
    const char *key = strstr(response, "\"job-id\"");
    if (key == NULL) {
        key = strstr(response, "\"job_id\"");
    }
    if (key == NULL || (key = strchr(key, ':')) == NULL) {
        return -1;
    }
    return strtol(key + 1, NULL, 10);
}

static int read_file(const char *path, unsigned char **bytes, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return errno ? errno : EIO;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return EIO;
    }
    long file_length = ftell(file);
    if (file_length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return EINVAL;
    }
    *bytes = malloc((size_t)file_length);
    if (*bytes == NULL) {
        fclose(file);
        return ENOMEM;
    }
    size_t read_length = fread(*bytes, 1, (size_t)file_length, file);
    fclose(file);
    if (read_length != (size_t)file_length) {
        free(*bytes);
        *bytes = NULL;
        return EIO;
    }
    *length = read_length;
    return 0;
}

static int send_job_data(Printer *printer, uint32_t job_id,
                         const unsigned char *image, size_t image_length) {
    unsigned char ack[4096];
    for (size_t offset = 0; offset < image_length; offset += DATA_CHUNK_SIZE) {
        size_t chunk_length = image_length - offset;
        if (chunk_length > DATA_CHUNK_SIZE) {
            chunk_length = DATA_CHUNK_SIZE;
        }
        char header[80];
        // EXTLEN covers the complete extension payload: the little-endian
        // four-byte job id followed by the JPEG bytes. Omitting the job id
        // makes every upload appear four bytes short to this firmware.
        size_t extension_length = sizeof(job_id) + chunk_length;
        int header_length = snprintf(header, sizeof(header), "cmd data EXTLEN=%zu\n",
                                     extension_length);
        size_t packet_length = (size_t)header_length + sizeof(job_id) + chunk_length;
        unsigned char *packet = malloc(packet_length);
        if (packet == NULL) {
            return LIBUSB_ERROR_NO_MEM;
        }
        memcpy(packet, header, (size_t)header_length);
        packet[header_length + 0] = (unsigned char)(job_id & 0xff);
        packet[header_length + 1] = (unsigned char)((job_id >> 8) & 0xff);
        packet[header_length + 2] = (unsigned char)((job_id >> 16) & 0xff);
        packet[header_length + 3] = (unsigned char)((job_id >> 24) & 0xff);
        memcpy(packet + header_length + sizeof(job_id), image + offset, chunk_length);
        int result = bulk_write_all(printer->handle, DATA_OUT, packet, packet_length, USB_WRITE_SIZE);
        free(packet);
        if (result != LIBUSB_SUCCESS) {
            return result;
        }
        int received_ack = 0;
        for (int attempt = 0; attempt < 12; ++attempt) {
            int ack_length = 0;
            result = libusb_bulk_transfer(printer->handle, DATA_IN, ack, sizeof(ack) - 1,
                                          &ack_length, USB_RESPONSE_TIMEOUT_MS);
            if (result != LIBUSB_SUCCESS) {
                return result;
            }
            if (ack_length <= 0) {
                continue;
            }
            ack[ack_length] = '\0';
            // JSON events can arrive between data frames on this model. Skip
            // them and wait for the firmware's explicit per-frame data ACK.
            if (strstr((char *)ack, "cmd data EXTLEN=") != NULL &&
                strstr((char *)ack, "OK") != NULL) {
                received_ack = 1;
                break;
            }
        }
        if (!received_ack) {
            return LIBUSB_ERROR_TIMEOUT;
        }
        usleep(20000);
    }
    return LIBUSB_SUCCESS;
}

static int run_status(void) {
    Printer printer;
    if (open_printer(&printer, 0) != 0) {
        return 1;
    }
    char status[65536];
    char info[65536];
    int result = query_status(&printer, status, sizeof(status), info, sizeof(info));
    close_printer(&printer);
    if (result != LIBUSB_SUCCESS) {
        return fail_libusb("读取打印机状态失败", result);
    }
    printf("{\"ok\":true,\"status\":%s,\"deviceInfo\":%s}\n", status, info);
    return 0;
}

static void sha1_hex(const unsigned char *bytes, size_t length,
                     char output[CC_SHA1_DIGEST_LENGTH * 2 + 1]) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(bytes, (CC_LONG)length, digest);
    for (int index = 0; index < CC_SHA1_DIGEST_LENGTH; ++index) {
        snprintf(output + index * 2, 3, "%02x", digest[index]);
    }
    output[CC_SHA1_DIGEST_LENGTH * 2] = '\0';
}

static int response_integer(const char *json, const char *field, long *value) {
    char marker[96];
    snprintf(marker, sizeof(marker), "\"%s\"", field);
    const char *position = strstr(json, marker);
    if (position == NULL || (position = strchr(position + strlen(marker), ':')) == NULL) {
        return 0;
    }
    char *end = NULL;
    long parsed = strtol(position + 1, &end, 10);
    if (end == position + 1) {
        return 0;
    }
    *value = parsed;
    return 1;
}

static int run_print(const char *path, int media_size, int media_type) {
    unsigned char *image = NULL;
    size_t image_length = 0;
    int file_result = read_file(path, &image, &image_length);
    if (file_result != 0) {
        print_error_json("无法读取待打印 JPEG 文件");
        return 1;
    }
    if (image_length < 4 || image[0] != 0xff || image[1] != 0xd8) {
        free(image);
        print_error_json("待打印文件不是有效的 JPEG");
        return 1;
    }

    Printer printer;
    if (open_printer(&printer, 1) != 0) {
        free(image);
        return 1;
    }
    char status[65536];
    char info[65536];
    int result = query_status(&printer, status, sizeof(status), info, sizeof(info));
    if (result != LIBUSB_SUCCESS) {
        close_printer(&printer);
        free(image);
        return fail_libusb("打印前状态检查失败", result);
    }
    if (strstr(status, "\"::0\"") == NULL) {
        char message[1024];
        snprintf(message, sizeof(message), "打印机状态未就绪：%.850s", status);
        close_printer(&printer);
        free(image);
        print_error_json(message);
        return 1;
    }

    char hash[CC_SHA1_DIGEST_LENGTH * 2 + 1];
    sha1_hex(image, image_length, hash);
    long sent_at = (long)time(NULL);
    char command[1024];
    snprintf(command, sizeof(command),
             "{\"method\":\"print-job\",\"params\":{"
             "\"media-size\":%d,\"media-type\":%d,\"job-type\":0,"
             "\"channel\":30784,\"file-size\":%zu,\"document-format\":9,"
             "\"document-name\":\"%ld.jpeg\",\"hash-method\":1,"
             "\"hash-value\":\"%s\","
             "\"user-account\":\"000000.00000000000000000000000000000000.0000\","
             "\"link-type\":1000,\"job-send-time\":%ld,\"copies\":1},"
             "\"id\":1003}", media_size, media_type, image_length, sent_at, hash, sent_at);
    char create_response[65536];
    result = send_json_command(&printer, command, 1003, create_response, sizeof(create_response));
    if (result != LIBUSB_SUCCESS) {
        close_printer(&printer);
        free(image);
        return fail_libusb("创建打印任务失败", result);
    }
    long job_id = parse_job_id(create_response);
    if (job_id < 0 || job_id > UINT32_MAX) {
        char message[1200];
        snprintf(message, sizeof(message), "打印机未返回有效的任务编号：%.1000s", create_response);
        close_printer(&printer);
        free(image);
        print_error_json(message);
        return 1;
    }
    result = send_job_data(&printer, (uint32_t)job_id, image, image_length);
    free(image);
    if (result != LIBUSB_SUCCESS) {
        close_printer(&printer);
        return fail_libusb("发送照片数据失败", result);
    }

    char job_response[65536] = "{}";
    int completed = 0;
    for (int poll = 0; poll < 120; ++poll) {
        int request_id = 1100 + poll;
        char poll_command[160];
        snprintf(poll_command, sizeof(poll_command),
                 "{\"method\":\"get-job-info\",\"params\":{\"job-id\":%ld},\"id\":%d}",
                 job_id, request_id);
        result = send_json_command(&printer, poll_command, request_id,
                                   job_response, sizeof(job_response));
        if (result == LIBUSB_SUCCESS) {
            long job_state = -1;
            long job_sub_state = -1;
            (void)response_integer(job_response, "job-sub-state", &job_sub_state);
            if (response_integer(job_response, "job-state", &job_state) &&
                (job_state == 7 || job_state == 8)) {
                char message[1200];
                snprintf(message, sizeof(message), "打印任务失败或被取消：%.1000s", job_response);
                close_printer(&printer);
                print_error_json(message);
                return 1;
            }
            if (job_state == 9) {
                completed = 1;
                break;
            }
            if (job_state == 5) {
                char pending_status[65536] = "{}";
                char pending_info[65536] = "{}";
                (void)query_status(&printer, pending_status, sizeof(pending_status),
                                   pending_info, sizeof(pending_info));
                char message[2200];
                snprintf(message, sizeof(message),
                         "打印任务暂停，可能是相纸/色带不匹配或进纸异常。请处理打印机后恢复任务，"
                         "不要重复发送。设备状态：%.850s；任务状态：%.1000s",
                         pending_status, job_response);
                close_printer(&printer);
                print_error_json(message);
                return 1;
            }
        }
        usleep(1000000);
    }
    close_printer(&printer);
    if (!completed) {
        char message[1200];
        snprintf(message, sizeof(message), "照片上传完成，但等待打印完成超时：%.1000s", job_response);
        print_error_json(message);
        return 1;
    }
    printf("{\"ok\":true,\"jobId\":%ld,\"createResponse\":%s,\"jobInfo\":%s}\n",
           job_id, create_response, job_response);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "status") == 0) {
        return run_status();
    }
    if ((argc >= 3 && argc <= 5) && strcmp(argv[1], "print") == 0) {
        int media_size = argc == 4 ? atoi(argv[3]) : 5012;
        if (argc == 5) {
            media_size = atoi(argv[3]);
        }
        int media_type = argc == 5 ? atoi(argv[4]) : 2010;
        return run_print(argv[2], media_size, media_type);
    }
    print_error_json("用法：MijiaUSBHelper status | print <jpeg> [media-size] [media-type]");
    return 64;
}
