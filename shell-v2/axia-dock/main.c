#include <gtk/gtk.h>
#include <gtk4-layer-shell/gtk4-layer-shell.h>
#include <gdk/wayland/gdkwayland.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gdesktopappinfo.h>
#include <graphene.h>
#include <math.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-activation-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

typedef struct _DockState DockState;

typedef struct {
    double item_size;
    double icon_size;
    double item_gap;
    double padding_x;
    double padding_y;
    double corner_radius;
    double tile_corner_radius;
    double top_margin;
    double bottom_margin;
} DockStyle;

typedef struct {
    char *id;
    char *title;
    gboolean focused;
    gboolean minimized;
    struct zwlr_foreign_toplevel_handle_v1 *handle;
} OpenApp;

typedef struct {
    DockState *owner;
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    char *app_id;
    char *title;
    gboolean activated;
    gboolean minimized;
    gboolean closed;
} ToplevelEntry;

typedef struct {
    GPtrArray *favorites;
    GPtrArray *recents;
} LauncherState;

typedef enum {
    ITEM_APP,
    ITEM_ALL_APPS,
} DockItemKind;

typedef struct {
    DockItemKind kind;
    char *app_id;
    char *title;
    gboolean open;
    gboolean focused;
    gboolean pinned;
    GtkWidget *button;
    GtkWidget *tile;
    GtkWidget *indicator;
} DockItem;

struct _DockState {
    GtkWidget *window;
    GtkWidget *root;
    GtkWidget *container;
    GtkWidget *row;
    DockStyle style;
    gchar *ipc_socket_path;
    GPtrArray *open_apps;
    GPtrArray *toplevels;
    GPtrArray *items;
    LauncherState launcher;
    guint preferences_timer;
    guint pending_rebuild_source;
    gint last_glass_x;
    gint last_glass_y;
    gint last_glass_w;
    gint last_glass_h;
    gint last_surface_h;
    gboolean glass_valid;
    gboolean drag_active;
    gint drag_source;
    gint drag_target;
    struct wl_display *wl_display;
    struct wl_registry *registry;
    struct wl_seat *wl_seat;
    struct xdg_activation_v1 *xdg_activation;
    struct zwlr_foreign_toplevel_manager_v1 *toplevel_manager;
    gboolean protocol_scan_complete;
    gboolean toplevel_protocol_available;
};

static void dock_state_free(DockState *state);

static void rebuild_dock(DockState *state);
static gboolean spawn_command(const char *command);
static void schedule_dock_rebuild(DockState *state);

static const char *get_launcher_command(void) {
    const char *env = g_getenv("AXIA_V2_LAUNCHER_CMD");
    if (env && *env) return env;
    return "axia-launcher";
}

static gboolean dock_glass_enabled(void) {
    const char *env = g_getenv("AXIA_V2_DOCK_GLASS");
    if (env == NULL || *env == '\0') return TRUE;
    return !(g_ascii_strcasecmp(env, "0") == 0 ||
             g_ascii_strcasecmp(env, "false") == 0 ||
             g_ascii_strcasecmp(env, "no") == 0 ||
             g_ascii_strcasecmp(env, "off") == 0);
}

static void open_app_free(gpointer data) {
    OpenApp *app = data;
    if (!app) return;
    g_free(app->id);
    g_free(app->title);
    g_free(app);
}

static void toplevel_entry_free(gpointer data) {
    ToplevelEntry *entry = data;
    if (!entry) return;
    if (entry->handle != NULL) zwlr_foreign_toplevel_handle_v1_destroy(entry->handle);
    g_free(entry->app_id);
    g_free(entry->title);
    g_free(entry);
}

static gchar *config_home(void) {
    const char *xdg = g_getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg) return g_strdup(xdg);
    const char *home = g_getenv("HOME");
    if (home && *home) return g_build_filename(home, ".config", NULL);
    return g_strdup(".config");
}

static gchar *preferences_path(void) {
    gchar *base = config_home();
    gchar *path = g_build_filename(base, "axia-de", "preferences.conf", NULL);
    g_free(base);
    return path;
}

static gchar *launcher_state_path(void) {
    gchar *base = config_home();
    gchar *path = g_build_filename(base, "axia-de", "launcher.conf", NULL);
    g_free(base);
    return path;
}

static gboolean is_valid_launcher_id(const char *id) {
    if (id == NULL || *id == '\0') return FALSE;
    if (!g_utf8_validate(id, -1, NULL)) return FALSE;
    for (const unsigned char *cursor = (const unsigned char *)id; *cursor != '\0'; cursor++) {
        if (*cursor < 0x20) return FALSE;
    }
    return TRUE;
}

static gboolean string_array_contains(GPtrArray *array, const char *value) {
    if (array == NULL || value == NULL || *value == '\0') return FALSE;
    for (guint i = 0; i < array->len; i++) {
        const char *item = g_ptr_array_index(array, i);
        if (g_strcmp0(item, value) == 0) return TRUE;
    }
    return FALSE;
}

static DockStyle style_from_preferences(const char *dock_size, const char *icon_size) {
    DockStyle style = {
        .item_size = 42,
        .icon_size = 32,
        .item_gap = 8,
        .padding_x = 18,
        .padding_y = 5,
        .corner_radius = 17,
        .tile_corner_radius = 9,
        .top_margin = 6,
        .bottom_margin = 1,
    };

    if (dock_size && g_ascii_strcasecmp(dock_size, "compact") == 0) {
        style.item_size = 36;
        style.icon_size = 26;
        style.item_gap = 6;
        style.padding_x = 14;
        style.padding_y = 4;
        style.corner_radius = 15;
        style.tile_corner_radius = 8;
        style.top_margin = 5;
        style.bottom_margin = 1;
    } else if (dock_size && g_ascii_strcasecmp(dock_size, "large") == 0) {
        style.item_size = 47;
        style.icon_size = 36;
        style.item_gap = 9;
        style.padding_x = 20;
        style.padding_y = 6;
        style.corner_radius = 19;
        style.tile_corner_radius = 10;
        style.top_margin = 7;
        style.bottom_margin = 1;
    }

    if (icon_size && g_ascii_strcasecmp(icon_size, "small") == 0) {
        style.icon_size -= 4;
    } else if (icon_size && g_ascii_strcasecmp(icon_size, "large") == 0) {
        style.icon_size += 4;
    }

    return style;
}

static DockStyle load_preferences(void) {
    gchar *path = preferences_path();
    gchar *contents = NULL;
    gsize len = 0;
    DockStyle style = style_from_preferences(NULL, NULL);

    if (g_file_get_contents(path, &contents, &len, NULL) && contents != NULL) {
        gchar **lines = g_strsplit(contents, "\n", -1);
        const char *dock_size = NULL;
        const char *dock_icon = NULL;
        for (gint i = 0; lines[i] != NULL; i++) {
            gchar *line = g_strstrip(lines[i]);
            if (line[0] == '\0' || line[0] == '#') continue;
            if (g_str_has_prefix(line, "dock_size=")) {
                dock_size = line + strlen("dock_size=");
            } else if (g_str_has_prefix(line, "dock_icon_size=")) {
                dock_icon = line + strlen("dock_icon_size=");
            }
        }
        style = style_from_preferences(dock_size, dock_icon);
        g_strfreev(lines);
    }

    g_free(contents);
    g_free(path);
    return style;
}

static LauncherState launcher_state_load(void) {
    LauncherState state = { .favorites = g_ptr_array_new_with_free_func(g_free),
                            .recents = g_ptr_array_new_with_free_func(g_free) };
    gchar *path = launcher_state_path();
    gchar *contents = NULL;
    gsize len = 0;

    if (g_file_get_contents(path, &contents, &len, NULL) && contents != NULL) {
        gchar **lines = g_strsplit(contents, "\n", -1);
        for (gint i = 0; lines[i] != NULL; i++) {
            gchar *line = g_strstrip(lines[i]);
            if (line[0] == '\0' || line[0] == '#') continue;
            if (g_str_has_prefix(line, "favorite=")) {
                const char *id = line + strlen("favorite=");
                if (is_valid_launcher_id(id) && !string_array_contains(state.favorites, id)) {
                    g_ptr_array_add(state.favorites, g_strdup(id));
                }
            } else if (g_str_has_prefix(line, "recent=")) {
                const char *id = line + strlen("recent=");
                if (is_valid_launcher_id(id) && !string_array_contains(state.recents, id)) {
                    g_ptr_array_add(state.recents, g_strdup(id));
                }
            }
        }
        g_strfreev(lines);
    }

    g_free(contents);
    g_free(path);
    return state;
}

static void launcher_state_save(LauncherState *state) {
    gchar *dir = g_build_filename(config_home(), "axia-de", NULL);
    g_mkdir_with_parents(dir, 0700);

    gchar *path = launcher_state_path();
    GString *out = g_string_new("# Axia-DE launcher state\n");

    for (guint i = 0; i < state->favorites->len; i++) {
        const char *id = g_ptr_array_index(state->favorites, i);
        g_string_append_printf(out, "favorite=%s\n", id);
    }
    for (guint i = 0; i < state->recents->len; i++) {
        const char *id = g_ptr_array_index(state->recents, i);
        g_string_append_printf(out, "recent=%s\n", id);
    }

    g_file_set_contents(path, out->str, -1, NULL);
    g_string_free(out, TRUE);
    g_free(path);
    g_free(dir);
}

static void launcher_state_free(LauncherState *state) {
    if (state->favorites) g_ptr_array_free(state->favorites, TRUE);
    if (state->recents) g_ptr_array_free(state->recents, TRUE);
}

static struct wl_surface *dock_wayland_surface(DockState *state) {
    if (state == NULL || state->window == NULL) return NULL;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(state->window));
    if (surface == NULL || !GDK_IS_WAYLAND_SURFACE(surface)) return NULL;
    return gdk_wayland_surface_get_wl_surface(surface);
}

static void flush_wayland(DockState *state) {
    if (state != NULL && state->wl_display != NULL) wl_display_flush(state->wl_display);
}

static gboolean ipc_request(const char *socket_path, const char *payload, gchar **response) {
    if (!socket_path || !payload) return FALSE;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return FALSE;

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return FALSE;
    }

    ssize_t sent = write(fd, payload, strlen(payload));
    if (sent < 0) {
        close(fd);
        return FALSE;
    }

    char buffer[4096];
    ssize_t read_len = read(fd, buffer, sizeof(buffer) - 1);
    if (read_len < 0) {
        close(fd);
        return FALSE;
    }
    buffer[read_len] = '\0';

    if (response) *response = g_strdup(buffer);
    close(fd);
    return TRUE;
}

static void ipc_update_glass(DockState *state, gint x, gint y, gint w, gint h, gint surface_h) {
    if (!state->ipc_socket_path) return;
    if (state->glass_valid &&
        state->last_glass_x == x &&
        state->last_glass_y == y &&
        state->last_glass_w == w &&
        state->last_glass_h == h &&
        state->last_surface_h == surface_h) {
        return;
    }

    gchar *payload = g_strdup_printf("dock glass %d %d %d %d %d\n", x, y, w, h, surface_h);
    ipc_request(state->ipc_socket_path, payload, NULL);
    g_free(payload);

    state->last_glass_x = x;
    state->last_glass_y = y;
    state->last_glass_w = w;
    state->last_glass_h = h;
    state->last_surface_h = surface_h;
    state->glass_valid = TRUE;
}

static void ipc_preview_show(DockState *state, const char *app_id, gint anchor_x) {
    if (!state->ipc_socket_path || !app_id || !*app_id) return;
    gchar *payload = g_strdup_printf("preview show %s %d\n", app_id, anchor_x);
    ipc_request(state->ipc_socket_path, payload, NULL);
    g_free(payload);
}

static void ipc_preview_hide(DockState *state) {
    if (!state->ipc_socket_path) return;
    ipc_request(state->ipc_socket_path, "preview hide\n", NULL);
}

static void ipc_focus_app(DockState *state, const char *app_id) {
    if (!state->ipc_socket_path || !app_id || !*app_id) return;
    gchar *payload = g_strdup_printf("app focus %s\n", app_id);
    ipc_request(state->ipc_socket_path, payload, NULL);
    g_free(payload);
}

static void ipc_close_app(DockState *state, const char *app_id) {
    if (!state->ipc_socket_path || !app_id || !*app_id) return;
    gchar *payload = g_strdup_printf("app close %s\n", app_id);
    ipc_request(state->ipc_socket_path, payload, NULL);
    g_free(payload);
}

static GPtrArray *ipc_get_open_apps(DockState *state) {
    GPtrArray *apps = g_ptr_array_new_with_free_func(g_free);
    gchar *response = NULL;
    if (!ipc_request(state->ipc_socket_path, "runtime get\n", &response) || response == NULL) {
        g_free(response);
        return apps;
    }

    gchar **lines = g_strsplit(response, "\n", -1);
    for (gint i = 0; lines[i] != NULL; i++) {
        gchar *line = g_strstrip(lines[i]);
        if (!g_str_has_prefix(line, "app ")) continue;
        gchar **tokens = g_strsplit(line, " ", 5);
        if (tokens[0] && tokens[1] && tokens[2] && tokens[3] && tokens[4]) {
            OpenApp *app = g_new0(OpenApp, 1);
            app->focused = atoi(tokens[2]) != 0;
            app->id = g_strdup(tokens[3]);
            app->title = g_strdup(tokens[4]);
            g_ptr_array_add(apps, app);
        }
        g_strfreev(tokens);
    }
    g_strfreev(lines);
    g_free(response);
    return apps;
}

static gboolean list_contains(GPtrArray *list, const char *id) {
    if (!list || !id) return FALSE;
    for (guint i = 0; i < list->len; i++) {
        const char *item = g_ptr_array_index(list, i);
        if (g_strcmp0(item, id) == 0) return TRUE;
    }
    return FALSE;
}

static void record_recent(LauncherState *state, const char *id) {
    if (!state || !is_valid_launcher_id(id)) return;
    for (guint i = 0; i < state->recents->len; i++) {
        const char *item = g_ptr_array_index(state->recents, i);
        if (g_strcmp0(item, id) == 0) {
            g_ptr_array_remove_index(state->recents, i);
            break;
        }
    }
    g_ptr_array_insert(state->recents, 0, g_strdup(id));
    while (state->recents->len > 8) {
        g_ptr_array_remove_index(state->recents, state->recents->len - 1);
    }
    launcher_state_save(state);
}

static gchar *normalize_icon_id(const char *raw) {
    if (!raw || !*raw) return NULL;
    gchar *copy = g_ascii_strdown(raw, -1);
    for (char *cursor = copy; *cursor; cursor++) {
        if (*cursor == '.' || *cursor == '_' || *cursor == ' ' || *cursor == '/') {
            *cursor = '-';
        }
    }
    return copy;
}

static const char *fallback_icon_name_for_app(const char *app_id) {
    if (app_id == NULL || *app_id == '\0') return "application-x-executable-symbolic";
    if (g_strrstr(app_id, "axia-files") != NULL || g_strrstr(app_id, "files") != NULL) {
        return "system-file-manager-symbolic";
    }
    if (g_strrstr(app_id, "axia-settings") != NULL || g_strrstr(app_id, "settings") != NULL) {
        return "preferences-system-symbolic";
    }
    if (g_strrstr(app_id, "firefox") != NULL || g_strrstr(app_id, "browser") != NULL || g_strrstr(app_id, "brave") != NULL) {
        return "web-browser-symbolic";
    }
    if (g_strrstr(app_id, "code") != NULL || g_strrstr(app_id, "vscodium") != NULL || g_strrstr(app_id, "zed") != NULL) {
        return "applications-development-symbolic";
    }
    if (g_strrstr(app_id, "alacritty") != NULL || g_strrstr(app_id, "terminal") != NULL || g_strrstr(app_id, "foot") != NULL) {
        return "utilities-terminal-symbolic";
    }
    return "application-x-executable-symbolic";
}

static GDesktopAppInfo *resolve_desktop_app_info(const char *app_id, gchar **resolved_id_out) {
    if (resolved_id_out != NULL) *resolved_id_out = NULL;
    if (app_id == NULL || *app_id == '\0') return NULL;

    GDesktopAppInfo *info = g_desktop_app_info_new(app_id);
    if (info != NULL) {
        if (resolved_id_out != NULL) *resolved_id_out = g_strdup(app_id);
        return info;
    }

    if (!g_str_has_suffix(app_id, ".desktop")) {
        gchar *desktop_id = g_strdup_printf("%s.desktop", app_id);
        info = g_desktop_app_info_new(desktop_id);
        if (info != NULL) {
            if (resolved_id_out != NULL) *resolved_id_out = desktop_id;
            else g_free(desktop_id);
            return info;
        }
        g_free(desktop_id);
    }

    gchar *normalized = normalize_icon_id(app_id);
    if (normalized != NULL && g_strcmp0(normalized, app_id) != 0) {
        info = g_desktop_app_info_new(normalized);
        if (info != NULL) {
            if (resolved_id_out != NULL) *resolved_id_out = g_strdup(normalized);
            g_free(normalized);
            return info;
        }

        if (!g_str_has_suffix(normalized, ".desktop")) {
            gchar *desktop_id = g_strdup_printf("%s.desktop", normalized);
            info = g_desktop_app_info_new(desktop_id);
            if (info != NULL) {
                if (resolved_id_out != NULL) *resolved_id_out = desktop_id;
                else g_free(desktop_id);
                g_free(normalized);
                return info;
            }
            g_free(desktop_id);
        }
    }

    gchar ***search = g_desktop_app_info_search(app_id);
    if (search != NULL) {
        for (guint i = 0; search[i] != NULL && info == NULL; i++) {
            for (guint j = 0; search[i][j] != NULL && info == NULL; j++) {
                info = g_desktop_app_info_new(search[i][j]);
                if (info != NULL && resolved_id_out != NULL) {
                    *resolved_id_out = g_strdup(search[i][j]);
                }
            }
        }
        for (guint i = 0; search[i] != NULL; i++) g_strfreev(search[i]);
        g_free(search);
    }

    g_free(normalized);
    return info;
}

static gboolean launch_internal_app(const char *app_id) {
    if (app_id == NULL || *app_id == '\0') return FALSE;

    const char *command = NULL;
    if (g_strcmp0(app_id, "axia-files") == 0) {
        command = "./zig-out/bin/axia-files";
    } else if (g_strcmp0(app_id, "axia-settings") == 0) {
        command = "./zig-out/bin/axia-settings";
    } else if (g_strcmp0(app_id, "axia-settings-network") == 0) {
        command = "./zig-out/bin/axia-settings network";
    } else if (g_strcmp0(app_id, "axia-settings-bluetooth") == 0) {
        command = "./zig-out/bin/axia-settings bluetooth";
    } else if (g_strcmp0(app_id, "axia-settings-printers") == 0) {
        command = "./zig-out/bin/axia-settings printers";
    }

    if (command == NULL) return FALSE;
    return spawn_command(command);
}

static char *find_axia_icon_path(const char * const *icon_names) {
    static const char *roots[] = {
        "assets/icons/Axia-Icons-shell",
        "assets/icons/Axia-Icons",
        NULL,
    };
    static const char *subdirs[] = {
        "apps",
        "places",
        "devices",
        "actions",
        "status",
        "mimetypes",
        NULL,
    };

    if (icon_names == NULL) return NULL;

    for (guint i = 0; icon_names[i] != NULL; i++) {
        for (guint r = 0; roots[r] != NULL; r++) {
            for (guint j = 0; subdirs[j] != NULL; j++) {
                char *path = g_strdup_printf("%s/%s/%s.svg", roots[r], subdirs[j], icon_names[i]);
                if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
                g_free(path);
            }
        }
    }

    return NULL;
}

static GtkWidget *build_icon_widget(const char * const *icon_names, int pixel_size) {
    char *local_path = find_axia_icon_path(icon_names);
    if (local_path != NULL) {
        GError *error = NULL;
        GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file_at_scale(local_path, pixel_size, pixel_size, TRUE, &error);
        GtkWidget *icon = NULL;
        if (pixbuf != NULL) {
            GdkTexture *texture = gdk_texture_new_for_pixbuf(pixbuf);
            icon = gtk_image_new_from_paintable(GDK_PAINTABLE(texture));
            g_object_unref(texture);
            g_object_unref(pixbuf);
        } else {
            g_clear_error(&error);
            icon = gtk_image_new_from_file(local_path);
            gtk_image_set_pixel_size(GTK_IMAGE(icon), pixel_size);
        }
        g_free(local_path);
        return icon;
    }

    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    if (theme != NULL && icon_names != NULL) {
        for (guint i = 0; icon_names[i] != NULL; i++) {
            if (gtk_icon_theme_has_icon(theme, icon_names[i])) {
                GtkWidget *icon = gtk_image_new_from_icon_name(icon_names[i]);
                gtk_image_set_pixel_size(GTK_IMAGE(icon), pixel_size);
                return icon;
            }
        }
    }

    GtkWidget *fallback = gtk_image_new_from_icon_name("application-x-executable-symbolic");
    gtk_image_set_pixel_size(GTK_IMAGE(fallback), pixel_size);
    return fallback;
}

static gchar *resolve_icon_for_app(const char *app_id) {
    if (!app_id || !*app_id) return g_strdup("application-x-executable-symbolic");

    gchar *resolved_id = NULL;
    GDesktopAppInfo *info = resolve_desktop_app_info(app_id, &resolved_id);
    if (info) {
        GIcon *icon = g_app_info_get_icon(G_APP_INFO(info));
        if (G_IS_THEMED_ICON(icon)) {
            const char *const *names = g_themed_icon_get_names(G_THEMED_ICON(icon));
            if (names && names[0]) {
                gchar *result = g_strdup(names[0]);
                g_object_unref(info);
                g_free(resolved_id);
                return result;
            }
        }
        g_object_unref(info);
    }

    g_free(resolved_id);

    const char *fallback = fallback_icon_name_for_app(app_id);
    const char *fallback_candidates[] = {
        fallback,
        app_id,
        NULL,
    };
    char *local_match = find_axia_icon_path(fallback_candidates);
    if (local_match != NULL) {
        gchar *base = g_path_get_basename(local_match);
        gchar *icon_name = g_strndup(base, strlen(base) - 4);
        g_free(base);
        g_free(local_match);
        return icon_name;
    }

    gchar *normalized = normalize_icon_id(app_id);
    if (normalized) return normalized;
    return g_strdup(fallback);
}

static gboolean launch_app(const char *app_id) {
    if (!app_id || !*app_id) return FALSE;
    if (launch_internal_app(app_id)) return TRUE;

    GDesktopAppInfo *info = resolve_desktop_app_info(app_id, NULL);
    if (info) {
        GError *error = NULL;
        gboolean ok = g_app_info_launch(G_APP_INFO(info), NULL, NULL, &error);
        if (!ok && error) g_clear_error(&error);
        g_object_unref(info);
        return ok;
    }

    char *gtk_launch = g_find_program_in_path("gtk-launch");
    if (gtk_launch) {
        gchar *resolved_id = NULL;
        GDesktopAppInfo *resolved = resolve_desktop_app_info(app_id, &resolved_id);
        if (resolved != NULL) g_object_unref(resolved);
        gchar *cmd = g_strdup_printf("gtk-launch %s", resolved_id != NULL ? resolved_id : app_id);
        gboolean ok = g_spawn_command_line_async(cmd, NULL);
        g_free(resolved_id);
        g_free(gtk_launch);
        g_free(cmd);
        return ok;
    }
    return FALSE;
}

typedef struct {
    DockState *state;
    char *command;
} LaunchRequest;

static void launch_request_free(LaunchRequest *request) {
    if (!request) return;
    g_free(request->command);
    g_free(request);
}

static gboolean spawn_command(const char *command) {
    if (command == NULL || *command == '\0') return FALSE;
    GError *error = NULL;
    const char *argv[] = { "sh", "-lc", command, NULL };
    gboolean ok = g_spawn_async(
        NULL,
        (char **)argv,
        NULL,
        G_SPAWN_SEARCH_PATH,
        NULL,
        NULL,
        NULL,
        &error);
    if (!ok && error != NULL) {
        g_printerr("axia-dock: failed to run command '%s': %s\n", command, error->message);
        g_clear_error(&error);
    }
    return ok;
}

static void activation_token_done(void *data, struct xdg_activation_token_v1 *token, const char *token_text) {
    LaunchRequest *request = data;
    gchar **envp = g_get_environ();
    if (token_text != NULL && token_text[0] != '\0') {
        gchar **updated = g_environ_setenv(envp, "XDG_ACTIVATION_TOKEN", token_text, TRUE);
        g_strfreev(envp);
        envp = updated;
        updated = g_environ_setenv(envp, "DESKTOP_STARTUP_ID", token_text, TRUE);
        g_strfreev(envp);
        envp = updated;
    }

    GError *error = NULL;
    const char *argv[] = { "sh", "-lc", request->command, NULL };
    gboolean ok = g_spawn_async(
        NULL,
        (char **)argv,
        envp,
        G_SPAWN_SEARCH_PATH,
        NULL,
        NULL,
        NULL,
        &error);
    if (!ok && error != NULL) {
        g_printerr("axia-dock: failed to run command '%s': %s\n", request->command, error->message);
        g_clear_error(&error);
    }

    g_strfreev(envp);
    xdg_activation_token_v1_destroy(token);
    launch_request_free(request);
}

static const struct xdg_activation_token_v1_listener activation_token_listener = {
    .done = activation_token_done,
};

static void spawn_command_activated(DockState *state, const char *command) {
    if (state == NULL || command == NULL || *command == '\0') return;
    if (state->xdg_activation == NULL) {
        spawn_command(command);
        return;
    }

    struct xdg_activation_token_v1 *token = xdg_activation_v1_get_activation_token(state->xdg_activation);
    if (token == NULL) {
        spawn_command(command);
        return;
    }

    LaunchRequest *request = g_new0(LaunchRequest, 1);
    request->state = state;
    request->command = g_strdup(command);

    struct wl_surface *wl_surface = dock_wayland_surface(state);
    if (wl_surface != NULL) xdg_activation_token_v1_set_surface(token, wl_surface);
    xdg_activation_token_v1_set_app_id(token, "org.axia.dock");
    xdg_activation_token_v1_add_listener(token, &activation_token_listener, request);
    xdg_activation_token_v1_commit(token);
    if (state->wl_display != NULL) wl_display_roundtrip(state->wl_display);
}

static void clear_items(DockState *state) {
    if (!state->items) return;
    for (guint i = 0; i < state->items->len; i++) {
        DockItem *item = g_ptr_array_index(state->items, i);
        g_free(item->app_id);
        g_free(item->title);
        g_free(item);
    }
    g_ptr_array_set_size(state->items, 0);
}

static gboolean rebuild_dock_idle(gpointer user_data) {
    DockState *state = user_data;
    if (state == NULL) return G_SOURCE_REMOVE;
    state->pending_rebuild_source = 0;
    rebuild_dock(state);
    return G_SOURCE_REMOVE;
}

static void schedule_dock_rebuild(DockState *state) {
    if (state == NULL) return;
    if (state->pending_rebuild_source != 0) return;
    state->pending_rebuild_source = g_idle_add(rebuild_dock_idle, state);
}

static OpenApp *find_open_app(GPtrArray *apps, const char *app_id) {
    if (!apps || !app_id) return NULL;
    for (guint i = 0; i < apps->len; i++) {
        OpenApp *app = g_ptr_array_index(apps, i);
        if (g_strcmp0(app->id, app_id) == 0) return app;
    }
    return NULL;
}

static void rebuild_open_apps(DockState *state) {
    if (state->open_apps != NULL) g_ptr_array_set_size(state->open_apps, 0);

    for (guint i = 0; i < state->toplevels->len; i++) {
        ToplevelEntry *entry = g_ptr_array_index(state->toplevels, i);
        if (entry->closed) continue;

        const char *app_id = (entry->app_id != NULL && entry->app_id[0] != '\0')
            ? entry->app_id
            : "application-x-executable-symbolic";
        OpenApp *app = find_open_app(state->open_apps, app_id);
        if (app == NULL) {
            app = g_new0(OpenApp, 1);
            app->id = g_strdup(app_id);
            app->title = g_strdup(
                (entry->title != NULL && entry->title[0] != '\0')
                    ? entry->title
                    : app_id);
            app->focused = entry->activated && !entry->minimized;
            app->minimized = entry->minimized;
            app->handle = entry->handle;
            g_ptr_array_add(state->open_apps, app);
            continue;
        }

        if (app->title == NULL || app->title[0] == '\0') {
            g_free(app->title);
            app->title = g_strdup(entry->title != NULL ? entry->title : app_id);
        }
        if (entry->activated && !entry->minimized) {
            app->focused = TRUE;
            app->minimized = FALSE;
            app->handle = entry->handle;
            g_free(app->title);
            app->title = g_strdup(
                (entry->title != NULL && entry->title[0] != '\0')
                    ? entry->title
                    : app_id);
        } else if (app->handle == NULL) {
            app->handle = entry->handle;
            app->minimized = entry->minimized;
        }
    }
}

static void sync_open_apps_and_rebuild(DockState *state) {
    rebuild_open_apps(state);
    rebuild_dock(state);
}

static void focus_open_app(DockState *state, OpenApp *app) {
    if (state == NULL || app == NULL || app->handle == NULL || state->wl_seat == NULL) return;
    if (app->minimized) zwlr_foreign_toplevel_handle_v1_unset_minimized(app->handle);
    zwlr_foreign_toplevel_handle_v1_activate(app->handle, state->wl_seat);
    flush_wayland(state);
}

static void minimize_open_app(DockState *state, OpenApp *app) {
    if (state == NULL || app == NULL || app->handle == NULL) return;
    zwlr_foreign_toplevel_handle_v1_set_minimized(app->handle);
    flush_wayland(state);
}

static void close_open_app(DockState *state, OpenApp *app) {
    if (state == NULL || app == NULL || app->handle == NULL) return;
    zwlr_foreign_toplevel_handle_v1_close(app->handle);
    flush_wayland(state);
}

static void on_item_clicked(GtkButton *button, gpointer user_data) {
    DockItem *item = user_data;
    DockState *state = g_object_get_data(G_OBJECT(button), "dock-state");
    if (!item || !state) return;

    if (item->kind == ITEM_ALL_APPS) {
        const char *launcher = get_launcher_command();
        spawn_command_activated(state, launcher);
        return;
    }

    if (item->open) {
        OpenApp *open = find_open_app(state->open_apps, item->app_id);
        if (open != NULL) {
            if (open->focused && !open->minimized) {
                minimize_open_app(state, open);
            } else {
                focus_open_app(state, open);
            }
        }
        return;
    }

    if (launch_app(item->app_id)) {
        record_recent(&state->launcher, item->app_id);
    }
}

static void on_item_enter(GtkEventControllerMotion *controller, double x, double y, gpointer user_data) {
    (void)x; (void)y;
    DockItem *item = user_data;
    DockState *state = g_object_get_data(G_OBJECT(controller), "dock-state");
    if (!item || !state || item->kind != ITEM_APP) return;
    if (item->button) gtk_widget_add_css_class(item->button, "dock-item-hover");
    if (item->tile) gtk_widget_add_css_class(item->tile, "dock-tile-visible");

    if (!item->open) return;

    if (!item->button || !state->container) return;
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(item->button, state->container, &bounds)) return;
    gint anchor_x = (gint)round(bounds.origin.x + bounds.size.width / 2.0);
    ipc_preview_show(state, item->app_id, anchor_x);
}

static void on_item_leave(GtkEventControllerMotion *controller, gpointer user_data) {
    DockItem *item = user_data;
    if (item != NULL) {
        if (item->button) gtk_widget_remove_css_class(item->button, "dock-item-hover");
        if (item->tile) gtk_widget_remove_css_class(item->tile, "dock-tile-visible");
    }
    DockState *state = g_object_get_data(G_OBJECT(controller), "dock-state");
    if (!state) return;
    ipc_preview_hide(state);
}

static void toggle_pin_state(DockState *state, DockItem *item) {
    if (state == NULL || item == NULL || item->kind != ITEM_APP) return;

    if (item->pinned) {
        for (guint i = 0; i < state->launcher.favorites->len; i++) {
            const char *id = g_ptr_array_index(state->launcher.favorites, i);
            if (g_strcmp0(id, item->app_id) == 0) {
                g_ptr_array_remove_index(state->launcher.favorites, i);
                break;
            }
        }
    } else if (is_valid_launcher_id(item->app_id) && !string_array_contains(state->launcher.favorites, item->app_id)) {
        g_ptr_array_add(state->launcher.favorites, g_strdup(item->app_id));
    }

    launcher_state_save(&state->launcher);
    schedule_dock_rebuild(state);
}

static void on_item_secondary_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)n_press;
    (void)x;
    (void)y;
    DockItem *item = user_data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    DockState *state = g_object_get_data(G_OBJECT(widget), "dock-state");
    if (!item || !state || item->kind != ITEM_APP) return;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    toggle_pin_state(state, item);
}

static void on_item_middle_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)n_press;
    (void)x;
    (void)y;
    DockItem *item = user_data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    DockState *state = g_object_get_data(G_OBJECT(widget), "dock-state");
    if (!item || !state || item->kind != ITEM_APP || !item->open) return;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    OpenApp *open = find_open_app(state->open_apps, item->app_id);
    if (open != NULL) close_open_app(state, open);
}

static void update_indicator(DockItem *item) {
    if (!item || !item->indicator) return;
    gtk_widget_set_visible(item->indicator, item->open);
    if (item->focused) {
        gtk_widget_add_css_class(item->indicator, "dock-indicator-active");
    } else {
        gtk_widget_remove_css_class(item->indicator, "dock-indicator-active");
    }
}

static GtkWidget *build_item_button(DockState *state, DockItem *item) {
    GtkWidget *button = gtk_button_new();
    gtk_widget_add_css_class(button, "dock-item");
    gtk_widget_set_size_request(button, (int)round(state->style.item_size), (int)round(state->style.item_size));
    gtk_widget_set_focusable(button, FALSE);

    GtkWidget *overlay = gtk_overlay_new();
    gtk_button_set_child(GTK_BUTTON(button), overlay);
    gtk_widget_set_halign(overlay, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(overlay, GTK_ALIGN_CENTER);

    GtkWidget *tile = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(tile, "dock-tile");
    gtk_widget_set_halign(tile, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(tile, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(
        tile,
        (int)round(MAX(state->style.icon_size + 10.0, state->style.item_size - 6.0)),
        (int)round(MAX(state->style.icon_size + 8.0, state->style.item_size - 8.0)));
    gtk_overlay_set_child(GTK_OVERLAY(overlay), tile);
    item->tile = tile;

    const char *icon_name = NULL;
    if (item->kind == ITEM_ALL_APPS) {
        icon_name = "application-menu-symbolic";
    } else {
        icon_name = item->app_id ? item->app_id : "application-x-executable-symbolic";
    }

    gchar *resolved = NULL;
    if (item->kind == ITEM_APP) resolved = resolve_icon_for_app(icon_name);
    const char *icon_candidates[] = {
        resolved ? resolved : icon_name,
        item->kind == ITEM_ALL_APPS ? "application-menu-symbolic" : "application-x-executable-symbolic",
        NULL,
    };
    GtkWidget *image = build_icon_widget(icon_candidates, (int)round(state->style.icon_size));
    gtk_widget_add_css_class(image, "dock-icon");
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), image);
    gtk_widget_set_halign(image, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(image, GTK_ALIGN_CENTER);

    GtkWidget *indicator = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(indicator, "dock-indicator");
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), indicator);
    gtk_widget_set_halign(indicator, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(indicator, GTK_ALIGN_END);
    gtk_widget_set_margin_bottom(indicator, 2);
    item->indicator = indicator;
    update_indicator(item);

    g_free(resolved);

    if (item->kind == ITEM_ALL_APPS) {
        gtk_widget_set_tooltip_text(button, "Aplicativos");
    } else if (item->title != NULL && item->title[0] != '\0') {
        gtk_widget_set_tooltip_text(button, item->title);
    } else if (item->app_id != NULL && item->app_id[0] != '\0') {
        gtk_widget_set_tooltip_text(button, item->app_id);
    }

    g_signal_connect(button, "clicked", G_CALLBACK(on_item_clicked), item);
    g_object_set_data(G_OBJECT(button), "dock-state", state);

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_object_set_data(G_OBJECT(motion), "dock-state", state);
    g_signal_connect(motion, "enter", G_CALLBACK(on_item_enter), item);
    g_signal_connect(motion, "leave", G_CALLBACK(on_item_leave), item);
    gtk_widget_add_controller(button, motion);

    GtkGesture *right_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(right_click), GDK_BUTTON_SECONDARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(right_click), GTK_PHASE_CAPTURE);
    g_object_set_data(G_OBJECT(right_click), "dock-state", state);
    g_signal_connect(right_click, "pressed", G_CALLBACK(on_item_secondary_pressed), item);
    gtk_widget_add_controller(button, GTK_EVENT_CONTROLLER(right_click));

    GtkGesture *middle_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(middle_click), GDK_BUTTON_MIDDLE);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(middle_click), GTK_PHASE_CAPTURE);
    g_object_set_data(G_OBJECT(middle_click), "dock-state", state);
    g_signal_connect(middle_click, "pressed", G_CALLBACK(on_item_middle_pressed), item);
    gtk_widget_add_controller(button, GTK_EVENT_CONTROLLER(middle_click));

    item->button = button;
    return button;
}

static void apply_layout(DockState *state) {
    guint item_count = state->items->len;
    double dock_width = state->style.padding_x * 2.0 +
                        item_count * state->style.item_size +
                        (item_count > 0 ? (item_count - 1) * state->style.item_gap : 0);
    double dock_height = state->style.item_size + state->style.padding_y * 2.0;
    double surface_height = dock_height + state->style.top_margin + state->style.bottom_margin;

    gtk_widget_set_size_request(state->container, (int)ceil(dock_width), (int)ceil(dock_height));
    gtk_widget_set_margin_top(state->container, (int)round(state->style.top_margin));
    gtk_widget_set_margin_bottom(state->container, (int)round(state->style.bottom_margin));

    gtk_window_set_default_size(GTK_WINDOW(state->window), 1, (int)ceil(surface_height));
    gtk_widget_set_size_request(state->root, -1, (int)ceil(surface_height));
    gtk_layer_set_exclusive_zone(GTK_WINDOW(state->window), (int)ceil(surface_height));
}

static void update_glass_region(DockState *state) {
    if (!dock_glass_enabled()) return;
    if (!state->container) return;
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(state->container, state->window, &bounds)) return;

    gint x = (gint)round(bounds.origin.x);
    gint y = (gint)round(bounds.origin.y);
    gint w = (gint)round(bounds.size.width);
    gint h = (gint)round(bounds.size.height);
    gint surface_h = gtk_widget_get_height(state->window);

    ipc_update_glass(state, x, y, w, h, surface_h);
}

static void rebuild_dock(DockState *state) {
    clear_items(state);
    if (state->row) {
        GtkWidget *child = gtk_widget_get_first_child(state->row);
        while (child) {
            GtkWidget *next = gtk_widget_get_next_sibling(child);
            gtk_box_remove(GTK_BOX(state->row), child);
            child = next;
        }
    }

    for (guint i = 0; i < state->launcher.favorites->len; i++) {
        const char *id = g_ptr_array_index(state->launcher.favorites, i);
        DockItem *item = g_new0(DockItem, 1);
        item->kind = ITEM_APP;
        item->app_id = g_strdup(id);
        item->pinned = TRUE;
        OpenApp *open = find_open_app(state->open_apps, id);
        if (open) {
            item->open = TRUE;
            item->focused = open->focused;
            item->title = g_strdup(open->title);
        }
        g_ptr_array_add(state->items, item);
    }

    for (guint i = 0; i < state->open_apps->len; i++) {
        OpenApp *open = g_ptr_array_index(state->open_apps, i);
        if (list_contains(state->launcher.favorites, open->id)) continue;
        DockItem *item = g_new0(DockItem, 1);
        item->kind = ITEM_APP;
        item->app_id = g_strdup(open->id);
        item->title = g_strdup(open->title);
        item->open = TRUE;
        item->focused = open->focused;
        g_ptr_array_add(state->items, item);
    }

    DockItem *all_apps = g_new0(DockItem, 1);
    all_apps->kind = ITEM_ALL_APPS;
    g_ptr_array_add(state->items, all_apps);

    for (guint i = 0; i < state->items->len; i++) {
        DockItem *item = g_ptr_array_index(state->items, i);
        GtkWidget *button = build_item_button(state, item);
        gtk_box_append(GTK_BOX(state->row), button);
    }

    apply_layout(state);
    update_glass_region(state);
}

static gboolean refresh_preferences(gpointer user_data) {
    DockState *state = user_data;
    DockStyle next = load_preferences();
    if (memcmp(&state->style, &next, sizeof(DockStyle)) != 0) {
        state->style = next;
        schedule_dock_rebuild(state);
    } else {
        apply_layout(state);
        update_glass_region(state);
    }
    return G_SOURCE_CONTINUE;
}

static gboolean initial_glass_sync(gpointer user_data) {
    DockState *state = user_data;
    if (!dock_glass_enabled()) {
        ipc_update_glass(state, 0, 0, 0, 0, gtk_widget_get_height(state->window));
        return G_SOURCE_REMOVE;
    }
    update_glass_region(state);
    return G_SOURCE_REMOVE;
}

static void toplevel_title(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, const char *title) {
    (void)handle;
    ToplevelEntry *entry = data;
    g_free(entry->title);
    entry->title = g_strdup(title);
}

static void toplevel_app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, const char *app_id) {
    (void)handle;
    ToplevelEntry *entry = data;
    g_free(entry->app_id);
    entry->app_id = g_strdup(app_id);
}

static void toplevel_output_enter(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct wl_output *output) {
    (void)data;
    (void)handle;
    (void)output;
}

static void toplevel_output_leave(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct wl_output *output) {
    (void)data;
    (void)handle;
    (void)output;
}

static void toplevel_state(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct wl_array *state_array) {
    (void)handle;
    ToplevelEntry *entry = data;
    entry->activated = FALSE;
    entry->minimized = FALSE;

    uint32_t *state_flag = NULL;
    wl_array_for_each(state_flag, state_array) {
        switch (*state_flag) {
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED:
                entry->activated = TRUE;
                break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED:
                entry->minimized = TRUE;
                break;
            default:
                break;
        }
    }
}

static void toplevel_done(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle) {
    (void)handle;
    ToplevelEntry *entry = data;
    if (entry->owner != NULL) {
        rebuild_open_apps(entry->owner);
        schedule_dock_rebuild(entry->owner);
    }
}

static void toplevel_closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle) {
    ToplevelEntry *entry = data;
    DockState *state = entry->owner;
    if (state == NULL) return;

    for (guint i = 0; i < state->toplevels->len; i++) {
        ToplevelEntry *candidate = g_ptr_array_index(state->toplevels, i);
        if (candidate != entry) continue;
        candidate->handle = NULL;
        candidate->closed = TRUE;
        g_ptr_array_remove_index(state->toplevels, i);
        break;
    }

    zwlr_foreign_toplevel_handle_v1_destroy(handle);
    rebuild_open_apps(state);
    schedule_dock_rebuild(state);
}

static void toplevel_parent(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct zwlr_foreign_toplevel_handle_v1 *parent) {
    (void)data;
    (void)handle;
    (void)parent;
}

static const struct zwlr_foreign_toplevel_handle_v1_listener toplevel_listener = {
    .title = toplevel_title,
    .app_id = toplevel_app_id,
    .output_enter = toplevel_output_enter,
    .output_leave = toplevel_output_leave,
    .state = toplevel_state,
    .done = toplevel_done,
    .closed = toplevel_closed,
    .parent = toplevel_parent,
};

static void toplevel_manager_toplevel(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager, struct zwlr_foreign_toplevel_handle_v1 *handle) {
    (void)manager;
    DockState *state = data;
    ToplevelEntry *entry = g_new0(ToplevelEntry, 1);
    entry->owner = state;
    entry->handle = handle;
    g_ptr_array_add(state->toplevels, entry);
    zwlr_foreign_toplevel_handle_v1_add_listener(handle, &toplevel_listener, entry);
}

static void toplevel_manager_finished(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager) {
    DockState *state = data;
    if (state->toplevel_manager == manager) state->toplevel_manager = NULL;
}

static const struct zwlr_foreign_toplevel_manager_v1_listener toplevel_manager_listener = {
    .toplevel = toplevel_manager_toplevel,
    .finished = toplevel_manager_finished,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    DockState *state = data;

    if (g_strcmp0(interface, wl_seat_interface.name) == 0) {
        state->wl_seat = wl_registry_bind(registry, name, &wl_seat_interface, MIN(version, 5));
        return;
    }

    if (g_strcmp0(interface, xdg_activation_v1_interface.name) == 0) {
        state->xdg_activation = wl_registry_bind(registry, name, &xdg_activation_v1_interface, 1);
        return;
    }

    if (g_strcmp0(interface, zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
        state->toplevel_protocol_available = TRUE;
        state->toplevel_manager = wl_registry_bind(registry, name, &zwlr_foreign_toplevel_manager_v1_interface, MIN(version, 3));
        zwlr_foreign_toplevel_manager_v1_add_listener(state->toplevel_manager, &toplevel_manager_listener, state);
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_remove,
};

static void initialize_protocols(DockState *state) {
    state->wl_display = wl_display_connect(NULL);
    if (state->wl_display == NULL) {
        state->protocol_scan_complete = TRUE;
        rebuild_dock(state);
        return;
    }

    state->registry = wl_display_get_registry(state->wl_display);
    wl_registry_add_listener(state->registry, &registry_listener, state);
    wl_display_roundtrip(state->wl_display);
    wl_display_roundtrip(state->wl_display);
    state->protocol_scan_complete = TRUE;
    rebuild_open_apps(state);
    schedule_dock_rebuild(state);
}

static void on_drag_begin(GtkGestureDrag *gesture, double start_x, double start_y, gpointer user_data) {
    (void)start_y;
    DockState *state = user_data;
    state->drag_active = FALSE;
    state->drag_source = -1;
    state->drag_target = -1;

    guint favorites = state->launcher.favorites->len;
    double x = start_x - state->style.padding_x;
    if (x < 0) return;
    int index = (int)floor(x / (state->style.item_size + state->style.item_gap));
    if (index < 0 || (guint)index >= favorites) return;
    state->drag_active = TRUE;
    state->drag_source = index;
    state->drag_target = index;
}

static void on_drag_update(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)offset_y;
    DockState *state = user_data;
    if (!state->drag_active) return;
    double start_x, start_y;
    gtk_gesture_drag_get_start_point(gesture, &start_x, &start_y);
    double x = start_x + offset_x - state->style.padding_x;
    int index = (int)floor(x / (state->style.item_size + state->style.item_gap));
    if (index < 0) index = 0;
    if ((guint)index >= state->launcher.favorites->len) index = (int)state->launcher.favorites->len - 1;
    state->drag_target = index;
}

static void on_drag_end(GtkGestureDrag *gesture, double offset_x, double offset_y, gpointer user_data) {
    (void)gesture; (void)offset_x; (void)offset_y;
    DockState *state = user_data;
    if (!state->drag_active) return;
    if (state->drag_source >= 0 && state->drag_target >= 0 &&
        state->drag_source != state->drag_target) {
        gpointer moved = g_ptr_array_steal_index(state->launcher.favorites, state->drag_source);
        g_ptr_array_insert(state->launcher.favorites, state->drag_target, moved);
        launcher_state_save(&state->launcher);
    }
    state->drag_active = FALSE;
    rebuild_dock(state);
}

static DockState *dock_state_new(GtkApplication *app) {
    DockState *state = g_new0(DockState, 1);
    state->ipc_socket_path = g_strdup(g_getenv("AXIA_IPC_SOCKET"));
    state->open_apps = g_ptr_array_new_with_free_func(open_app_free);
    state->toplevels = g_ptr_array_new_with_free_func(toplevel_entry_free);
    state->items = g_ptr_array_new();
    state->launcher = launcher_state_load();
    launcher_state_save(&state->launcher);
    state->style = load_preferences();

    state->window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(state->window), "Axia Dock");
    gtk_window_set_decorated(GTK_WINDOW(state->window), FALSE);
    gtk_widget_add_css_class(state->window, "dock-window");

    gtk_layer_init_for_window(GTK_WINDOW(state->window));
    gtk_layer_set_namespace(GTK_WINDOW(state->window), "axia-dock");
    gtk_layer_set_layer(GTK_WINDOW(state->window), GTK_LAYER_SHELL_LAYER_TOP);
    gtk_layer_set_anchor(GTK_WINDOW(state->window), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
    gtk_layer_set_anchor(GTK_WINDOW(state->window), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
    gtk_layer_set_anchor(GTK_WINDOW(state->window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
    gtk_layer_set_keyboard_mode(GTK_WINDOW(state->window), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
    gtk_layer_set_respect_close(GTK_WINDOW(state->window), TRUE);

    state->root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(state->root, "dock-root");
    gtk_window_set_child(GTK_WINDOW(state->window), state->root);

    GtkWidget *center = gtk_center_box_new();
    gtk_widget_set_hexpand(center, TRUE);
    gtk_widget_set_halign(center, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class(center, "dock-center");
    gtk_box_append(GTK_BOX(state->root), center);

    state->container = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(state->container, "dock-container");
    gtk_widget_set_valign(state->container, GTK_ALIGN_END);
    gtk_center_box_set_center_widget(GTK_CENTER_BOX(center), state->container);

    state->row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, (int)round(state->style.item_gap));
    gtk_widget_add_css_class(state->row, "dock-row");
    gtk_box_append(GTK_BOX(state->container), state->row);

    rebuild_dock(state);
    initialize_protocols(state);
    state->preferences_timer = g_timeout_add(800, refresh_preferences, state);
    g_timeout_add(200, initial_glass_sync, state);

    return state;
}

static void dock_state_free(DockState *state) {
    if (!state) return;
    if (state->preferences_timer) g_source_remove(state->preferences_timer);
    if (state->pending_rebuild_source) g_source_remove(state->pending_rebuild_source);
    if (state->ipc_socket_path) {
        ipc_update_glass(state, 0, 0, 0, 0, 0);
    }
    if (state->open_apps) g_ptr_array_free(state->open_apps, TRUE);
    if (state->toplevels) g_ptr_array_free(state->toplevels, TRUE);
    if (state->items) g_ptr_array_free(state->items, TRUE);
    if (state->toplevel_manager) zwlr_foreign_toplevel_manager_v1_destroy(state->toplevel_manager);
    if (state->xdg_activation) xdg_activation_v1_destroy(state->xdg_activation);
    if (state->wl_seat) wl_seat_destroy(state->wl_seat);
    if (state->registry) wl_registry_destroy(state->registry);
    if (state->wl_display) wl_display_disconnect(state->wl_display);
    launcher_state_free(&state->launcher);
    g_free(state->ipc_socket_path);
    g_free(state);
}

static void apply_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider, "shell-v2/axia-dock/style.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static void on_activate(GtkApplication *app, gpointer user_data) {
    (void)user_data;
    apply_css();
    DockState *state = dock_state_new(app);
    g_object_set_data_full(G_OBJECT(state->window), "dock-state", state, (GDestroyNotify)dock_state_free);
    gtk_window_present(GTK_WINDOW(state->window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.axia.dock", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
