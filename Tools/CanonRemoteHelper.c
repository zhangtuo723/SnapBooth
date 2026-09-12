#include <gphoto2/gphoto2.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct {
    char folder[2048];
    char name[512];
    time_t mtime;
    int found;
} LatestImage;

static int is_supported_image(const char *name) {
    const char *extension = strrchr(name, '.');
    if (!extension) return 0;
    return strcasecmp(extension, ".jpg") == 0 ||
           strcasecmp(extension, ".jpeg") == 0 ||
           strcasecmp(extension, ".heif") == 0 ||
           strcasecmp(extension, ".hif") == 0;
}

static void find_latest_image(Camera *camera, GPContext *context, const char *folder, LatestImage *latest) {
    CameraList *files = NULL;
    if (gp_list_new(&files) >= GP_OK && gp_camera_folder_list_files(camera, folder, files, context) >= GP_OK) {
        int count = gp_list_count(files);
        for (int index = 0; index < count; index++) {
            const char *name = NULL;
            gp_list_get_name(files, index, &name);
            if (!name || !is_supported_image(name)) continue;
            CameraFileInfo info;
            memset(&info, 0, sizeof(info));
            time_t mtime = 0;
            if (gp_camera_file_get_info(camera, folder, name, &info, context) >= GP_OK &&
                (info.file.fields & GP_FILE_INFO_MTIME)) {
                mtime = info.file.mtime;
            }
            if (!latest->found || mtime > latest->mtime ||
                (mtime == latest->mtime && strcasecmp(name, latest->name) > 0)) {
                snprintf(latest->folder, sizeof(latest->folder), "%s", folder);
                snprintf(latest->name, sizeof(latest->name), "%s", name);
                latest->mtime = mtime;
                latest->found = 1;
            }
        }
    }
    if (files) gp_list_free(files);

    CameraList *folders = NULL;
    if (gp_list_new(&folders) < GP_OK) return;
    if (gp_camera_folder_list_folders(camera, folder, folders, context) >= GP_OK) {
        int count = gp_list_count(folders);
        for (int index = 0; index < count; index++) {
            const char *name = NULL;
            gp_list_get_name(folders, index, &name);
            if (!name) continue;
            char child[2048];
            if (strcmp(folder, "/") == 0) {
                snprintf(child, sizeof(child), "/%s", name);
            } else {
                snprintf(child, sizeof(child), "%s/%s", folder, name);
            }
            find_latest_image(camera, context, child, latest);
        }
    }
    gp_list_free(folders);
}

static void configure_homebrew_driver_paths(void) {
    glob_t matches = {0};
    if (glob("/opt/homebrew/opt/libgphoto2/lib/libgphoto2/*", 0, NULL, &matches) == 0 && matches.gl_pathc > 0) {
        setenv("CAMLIBS", matches.gl_pathv[0], 1);
    }
    globfree(&matches);
    memset(&matches, 0, sizeof(matches));
    if (glob("/opt/homebrew/opt/libgphoto2/lib/libgphoto2_port/*", 0, NULL, &matches) == 0 && matches.gl_pathc > 0) {
        setenv("IOLIBS", matches.gl_pathv[0], 1);
    }
    globfree(&matches);
}

static int open_camera(Camera **camera_out, GPContext **context_out, char *name_out, size_t name_size) {
    int result;
    CameraList *detected = NULL;
    CameraAbilitiesList *abilities = NULL;
    GPPortInfoList *ports = NULL;
    GPContext *context = gp_context_new();
    if (!context) return GP_ERROR_NO_MEMORY;

    if ((result = gp_list_new(&detected)) < GP_OK) goto fail;
    if ((result = gp_camera_autodetect(detected, context)) < GP_OK) {
        goto fail;
    }

    const char *model = NULL;
    const char *port_path = NULL;
    int count = gp_list_count(detected);
    for (int index = 0; index < count; index++) {
        const char *candidate_model = NULL;
        const char *candidate_port = NULL;
        gp_list_get_name(detected, index, &candidate_model);
        gp_list_get_value(detected, index, &candidate_port);
        if (candidate_model && strstr(candidate_model, "Canon EOS R50 V")) {
            model = candidate_model;
            port_path = candidate_port;
            break;
        }
    }
    if (!model || !port_path) {
        result = GP_ERROR_MODEL_NOT_FOUND;
        goto fail;
    }

    if ((result = gp_abilities_list_new(&abilities)) < GP_OK) goto fail;
    if ((result = gp_abilities_list_load(abilities, context)) < GP_OK) goto fail;
    int ability_index = gp_abilities_list_lookup_model(abilities, model);
    if (ability_index < GP_OK) { result = ability_index; goto fail; }
    CameraAbilities camera_abilities;
    if ((result = gp_abilities_list_get_abilities(abilities, ability_index, &camera_abilities)) < GP_OK) goto fail;

    if ((result = gp_port_info_list_new(&ports)) < GP_OK) goto fail;
    if ((result = gp_port_info_list_load(ports)) < GP_OK) goto fail;
    int port_index = gp_port_info_list_lookup_path(ports, port_path);
    if (port_index < GP_OK) { result = port_index; goto fail; }
    GPPortInfo port_info;
    if ((result = gp_port_info_list_get_info(ports, port_index, &port_info)) < GP_OK) goto fail;

    Camera *camera = NULL;
    if ((result = gp_camera_new(&camera)) < GP_OK) goto fail;
    if ((result = gp_camera_set_abilities(camera, camera_abilities)) < GP_OK ||
        (result = gp_camera_set_port_info(camera, port_info)) < GP_OK ||
        (result = gp_camera_init(camera, context)) < GP_OK) {
        gp_camera_free(camera);
        goto fail;
    }

    snprintf(name_out, name_size, "%s", model);
    gp_list_free(detected);
    gp_abilities_list_free(abilities);
    gp_port_info_list_free(ports);
    *camera_out = camera;
    *context_out = context;
    return GP_OK;

fail:
    if (detected) gp_list_free(detected);
    if (abilities) gp_abilities_list_free(abilities);
    if (ports) gp_port_info_list_free(ports);
    gp_context_unref(context);
    return result;
}

static void respond_error(int code) {
    printf("ERROR\t%d\t%s\n", code, gp_result_as_string(code));
    fflush(stdout);
}

int main(void) {
    configure_homebrew_driver_paths();
    Camera *camera = NULL;
    GPContext *context = NULL;
    char camera_name[256] = {0};
    int result = open_camera(&camera, &context, camera_name, sizeof(camera_name));
    if (result < GP_OK) {
        respond_error(result);
        return 2;
    }

    printf("READY\t%s\n", camera_name);
    fflush(stdout);

    char command[4096];
    while (fgets(command, sizeof(command), stdin)) {
        command[strcspn(command, "\r\n")] = '\0';
        if (strcmp(command, "QUIT") == 0) {
            printf("BYE\n");
            fflush(stdout);
            break;
        }
        if (strncmp(command, "PREVIEW\t", 8) == 0) {
            const char *destination = command + 8;
            CameraFile *file = NULL;
            result = gp_file_new(&file);
            if (result >= GP_OK) result = gp_camera_capture_preview(camera, file, context);
            if (result >= GP_OK) result = gp_file_save(file, destination);
            if (file) gp_file_free(file);
            if (result < GP_OK) {
                respond_error(result);
            } else {
                printf("OK\tPREVIEW\n");
                fflush(stdout);
            }
            continue;
        }
        if (strncmp(command, "LATEST\t", 7) == 0) {
            const char *destination = command + 7;
            LatestImage latest = {0};
            find_latest_image(camera, context, "/", &latest);
            if (!latest.found) {
                respond_error(GP_ERROR_FILE_NOT_FOUND);
                continue;
            }
            CameraFile *file = NULL;
            result = gp_file_new(&file);
            if (result >= GP_OK) {
                result = gp_camera_file_get(
                    camera, latest.folder, latest.name, GP_FILE_TYPE_NORMAL, file, context
                );
            }
            if (result >= GP_OK) result = gp_file_save(file, destination);
            if (file) gp_file_free(file);
            if (result < GP_OK) {
                respond_error(result);
            } else {
                printf("OK\tLATEST\t%s\n", latest.name);
                fflush(stdout);
            }
            continue;
        }
        printf("ERROR\t-1\tUnknown command\n");
        fflush(stdout);
    }

    gp_camera_exit(camera, context);
    gp_camera_free(camera);
    gp_context_unref(context);
    return 0;
}
