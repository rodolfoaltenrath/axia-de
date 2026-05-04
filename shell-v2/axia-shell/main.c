#include <gtk/gtk.h>
#include <gtk4-layer-shell/gtk4-layer-shell.h>
#include <gdk/wayland/gdkwayland.h>
#include <gio/gdesktopappinfo.h>
#include <pango/pango.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-workspace-v1-client-protocol.h"
#include "xdg-activation-v1-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

typedef struct _ShellState ShellState;

typedef struct {
    ShellState *owner;
    struct ext_workspace_handle_v1 *handle;
    char *name;
    uint32_t state;
    uint32_t capabilities;
    GtkWidget *button;
} WorkspaceItem;

typedef struct {
    ShellState *owner;
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    char *title;
    char *app_id;
    gboolean activated;
    gboolean maximized;
    gboolean minimized;
    gboolean fullscreen;
    GtkWidget *button;
    GtkWidget *popover;
} ToplevelItem;

typedef enum {
    TOPLEVEL_ACTION_ACTIVATE,
    TOPLEVEL_ACTION_TOGGLE_MINIMIZED,
    TOPLEVEL_ACTION_TOGGLE_MAXIMIZED,
    TOPLEVEL_ACTION_TOGGLE_FULLSCREEN,
    TOPLEVEL_ACTION_CLOSE,
} ToplevelAction;

typedef struct {
    ToplevelItem *item;
    ToplevelAction action;
    GtkPopover *popover;
} ToplevelActionPayload;

typedef struct {
    ShellState *owner;
    char *command;
} SpawnCommandRequest;

struct _ShellState {
    GWeakRef clock_ref;
    GWeakRef audio_label_ref;
    GWeakRef audio_icon_ref;
    GtkApplication *app;
    GtkWidget *window;
    GtkWidget *power_window;
    GtkWidget *workspace_box;
    GtkWidget *window_box;
    GtkWidget *bluetooth_button;
    GtkWidget *bluetooth_icon;
    GtkWidget *network_button;
    GtkWidget *network_icon;
    GtkWidget *battery_button;
    GtkWidget *battery_icon;
    struct wl_display *wl_display;
    struct wl_registry *registry;
    struct wl_seat *wl_seat;
    struct ext_workspace_manager_v1 *workspace_manager;
    struct xdg_activation_v1 *xdg_activation;
    struct zwlr_foreign_toplevel_manager_v1 *toplevel_manager;
    GPtrArray *workspaces;
    GPtrArray *toplevels;
    gboolean protocols_disabled;
    gboolean protocol_scan_complete;
    gboolean workspace_protocol_available;
    gboolean toplevel_protocol_available;
};

static char *find_axia_icon_path(const char * const *icon_names);
static void set_icon_from_candidates(GtkWidget *image, const char * const *icon_names);

static GdkMonitor *preferred_monitor(void) {
    GdkDisplay *display = gdk_display_get_default();
    if (display == NULL) return NULL;

    GListModel *monitors = gdk_display_get_monitors(display);
    if (monitors == NULL) return NULL;
    if (g_list_model_get_n_items(monitors) == 0) return NULL;

    return GDK_MONITOR(g_list_model_get_item(monitors, 0));
}

static void apply_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider, "shell-v2/axia-shell/style.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static gboolean spawn_shell_command(const char *command) {
    const char *argv[] = { "sh", "-lc", command, NULL };
    GError *error = NULL;
    gboolean ok = g_spawn_async(
        NULL,
        (char **)argv,
        NULL,
        G_SPAWN_SEARCH_PATH,
        NULL,
        NULL,
        NULL,
        &error);
    if (!ok) {
        g_printerr("axia-shell-v2: failed to run command '%s': %s\n", command, error->message);
        g_clear_error(&error);
    }
    return ok;
}

static gboolean spawn_program(const char *program) {
    GError *error = NULL;
    const char *argv[] = { program, NULL };
    gboolean ok = g_spawn_async(
        NULL,
        (char **)argv,
        NULL,
        G_SPAWN_SEARCH_PATH,
        NULL,
        NULL,
        NULL,
        &error);
    if (!ok) {
        g_printerr("axia-shell-v2: failed to run program '%s': %s\n", program, error->message);
        g_clear_error(&error);
    }
    return ok;
}

static gboolean shell_protocols_disabled(void) {
    const char *env = g_getenv("AXIA_V2_DISABLE_SHELL_PROTOCOLS");
    if (env == NULL || *env == '\0') return FALSE;
    return g_ascii_strcasecmp(env, "1") == 0 ||
           g_ascii_strcasecmp(env, "true") == 0 ||
           g_ascii_strcasecmp(env, "yes") == 0 ||
           g_ascii_strcasecmp(env, "on") == 0;
}

static void noop_button(GtkButton *button, gpointer user_data) {
    (void)button;
    (void)user_data;
}

static gboolean spawn_shell_command_with_env(const char *command, const char * const *env_pairs) {
    GError *error = NULL;
    gchar **custom_env = g_get_environ();

    if (env_pairs != NULL) {
        for (guint i = 0; env_pairs[i] != NULL; i += 2) {
            if (env_pairs[i + 1] == NULL) break;
            gchar **updated = g_environ_setenv(custom_env, env_pairs[i], env_pairs[i + 1], TRUE);
            g_strfreev(custom_env);
            custom_env = updated;
        }
    }

    const char *argv[] = { "sh", "-lc", command, NULL };
    gboolean ok = g_spawn_async(
        NULL,
        (char **)argv,
        custom_env,
        G_SPAWN_SEARCH_PATH,
        NULL,
        NULL,
        NULL,
        &error);
    if (!ok) {
        g_printerr("axia-shell-v2: failed to run command '%s': %s\n", command, error->message);
        g_clear_error(&error);
    }

    g_strfreev(custom_env);
    return ok;
}

static gboolean run_command_capture(const char *command, char **stdout_text) {
    GError *error = NULL;
    char *stderr_text = NULL;
    int exit_status = 0;
    gboolean ok = g_spawn_command_line_sync(command, stdout_text, &stderr_text, &exit_status, &error);
    if (!ok) {
        g_printerr("axia-shell-v2: failed to capture command '%s': %s\n", command, error->message);
        g_clear_error(&error);
        g_free(stderr_text);
        return FALSE;
    }
    g_free(stderr_text);
    return exit_status == 0;
}

static void flush_wayland(ShellState *state) {
    if (state->wl_display != NULL) wl_display_flush(state->wl_display);
}

static struct wl_surface *shell_wayland_surface(ShellState *state) {
    if (state == NULL || state->window == NULL) return NULL;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(state->window));
    if (surface == NULL || !GDK_IS_WAYLAND_SURFACE(surface)) return NULL;
    return gdk_wayland_surface_get_wl_surface(surface);
}

static void spawn_command_request_free(SpawnCommandRequest *request) {
    if (request == NULL) return;
    g_free(request->command);
    g_free(request);
}

static void workspace_item_free(gpointer data) {
    WorkspaceItem *item = data;
    if (item->button != NULL) item->button = NULL;
    if (item->handle != NULL) ext_workspace_handle_v1_destroy(item->handle);
    g_free(item->name);
    g_free(item);
}

static void toplevel_item_free(gpointer data) {
    ToplevelItem *item = data;
    if (item->popover != NULL) item->popover = NULL;
    if (item->button != NULL) item->button = NULL;
    if (item->handle != NULL) zwlr_foreign_toplevel_handle_v1_destroy(item->handle);
    g_free(item->title);
    g_free(item->app_id);
    g_free(item);
}

static void shell_state_free(gpointer data) {
    ShellState *state = data;

    if (state->power_window != NULL) {
        gtk_window_destroy(GTK_WINDOW(state->power_window));
        state->power_window = NULL;
    }

    if (state->workspaces != NULL) g_ptr_array_free(state->workspaces, TRUE);
    if (state->toplevels != NULL) g_ptr_array_free(state->toplevels, TRUE);

    if (state->workspace_manager != NULL) {
        ext_workspace_manager_v1_stop(state->workspace_manager);
        ext_workspace_manager_v1_destroy(state->workspace_manager);
    }
    if (state->xdg_activation != NULL) xdg_activation_v1_destroy(state->xdg_activation);
    if (state->toplevel_manager != NULL) {
        zwlr_foreign_toplevel_manager_v1_stop(state->toplevel_manager);
        zwlr_foreign_toplevel_manager_v1_destroy(state->toplevel_manager);
    }
    if (state->wl_seat != NULL) wl_seat_destroy(state->wl_seat);
    if (state->registry != NULL) wl_registry_destroy(state->registry);
    if (state->wl_display != NULL) wl_display_disconnect(state->wl_display);

    g_weak_ref_clear(&state->clock_ref);
    g_weak_ref_clear(&state->audio_label_ref);
    g_weak_ref_clear(&state->audio_icon_ref);
    g_free(state);
}

static gboolean update_clock(gpointer data) {
    ShellState *state = data;
    GtkWidget *clock = g_weak_ref_get(&state->clock_ref);
    if (clock == NULL) return G_SOURCE_REMOVE;

    GDateTime *now = g_date_time_new_now_local();
    char *label = g_date_time_format(now, "%d de %b., %H:%M");
    gtk_label_set_text(GTK_LABEL(clock), label);
    g_free(label);
    g_date_time_unref(now);
    g_object_unref(clock);
    return G_SOURCE_CONTINUE;
}

static gboolean parse_audio_state(double *volume_out, gboolean *muted_out) {
    char *stdout_text = NULL;
    if (!run_command_capture("wpctl get-volume @DEFAULT_AUDIO_SINK@", &stdout_text)) return FALSE;

    gboolean muted = stdout_text != NULL && g_strstr_len(stdout_text, -1, "[MUTED]") != NULL;
    double volume = 0.0;

    if (stdout_text != NULL) {
        const char *volume_pos = g_strstr_len(stdout_text, -1, "Volume:");
        if (volume_pos != NULL) volume = g_ascii_strtod(volume_pos + 7, NULL);
    }

    g_free(stdout_text);
    *volume_out = CLAMP(volume, 0.0, 1.5);
    *muted_out = muted;
    return TRUE;
}

static gboolean update_audio_label(gpointer data) {
    ShellState *state = data;
    GtkWidget *audio_label = g_weak_ref_get(&state->audio_label_ref);
    GtkWidget *audio_icon = g_weak_ref_get(&state->audio_icon_ref);
    if (audio_label == NULL) return G_SOURCE_REMOVE;

    double volume = 0.0;
    gboolean muted = FALSE;
    if (parse_audio_state(&volume, &muted)) {
        char *text = muted
            ? g_strdup("Som mudo")
            : g_strdup_printf("Som %d%%", (int)(volume * 100.0 + 0.5));
        gtk_label_set_text(GTK_LABEL(audio_label), text);
        g_free(text);

        if (audio_icon != NULL) {
            if (muted) {
                static const char * const icons[] = {
                    "audio-volume-muted-symbolic",
                    "audio-speakers-symbolic",
                    "preferences-sound-symbolic",
                    NULL,
                };
                set_icon_from_candidates(audio_icon, icons);
            } else if (volume < 0.34) {
                static const char * const icons[] = {
                    "audio-volume-low-symbolic",
                    "audio-speakers-symbolic",
                    "preferences-sound-symbolic",
                    NULL,
                };
                set_icon_from_candidates(audio_icon, icons);
            } else if (volume < 0.67) {
                static const char * const icons[] = {
                    "audio-volume-medium-symbolic",
                    "audio-speakers-symbolic",
                    "preferences-sound-symbolic",
                    NULL,
                };
                set_icon_from_candidates(audio_icon, icons);
            } else {
                static const char * const icons[] = {
                    "audio-volume-high-symbolic",
                    "audio-speakers-symbolic",
                    "preferences-sound-symbolic",
                    NULL,
                };
                set_icon_from_candidates(audio_icon, icons);
            }
        }
    } else {
        gtk_label_set_text(GTK_LABEL(audio_label), "Som --");
    }

    g_object_unref(audio_label);
    if (audio_icon != NULL) g_object_unref(audio_icon);
    return G_SOURCE_CONTINUE;
}

static char *find_axia_icon_path(const char * const *icon_names) {
    static const char *roots[] = {
        "assets/icons/Axia-Icons-shell",
        "assets/icons/Axia-Icons",
        NULL,
    };
    static const char *subdirs[] = {
        "status",
        "devices",
        "actions",
        "apps",
        "places",
        "mimetypes",
        NULL,
    };

    if (icon_names == NULL) return NULL;

    for (guint i = 0; icon_names[i] != NULL; i++) {
        for (guint r = 0; roots[r] != NULL; r++) {
            for (guint j = 0; subdirs[j] != NULL; j++) {
                char *path = g_strdup_printf(
                    "%s/%s/%s.svg",
                    roots[r],
                    subdirs[j],
                    icon_names[i]);
                if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
                g_free(path);
            }
        }

        if (g_str_has_prefix(icon_names[i], "battery-")) {
            for (guint r = 0; roots[r] != NULL; r++) {
                for (guint j = 0; subdirs[j] != NULL; j++) {
                    char *path = g_strdup_printf(
                        "%s/%s/battery-symbolic.svg",
                        roots[r],
                        subdirs[j]);
                    if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
                    g_free(path);
                }
            }
        }

        if (g_strcmp0(icon_names[i], "network-offline-symbolic") == 0) {
            for (guint r = 0; roots[r] != NULL; r++) {
                char *path = g_strdup_printf("%s/status/network-disconnected-symbolic.svg", roots[r]);
                if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
                g_free(path);
            }
        }

        if (g_str_has_prefix(icon_names[i], "preferences-system-notifications") ||
            g_strcmp0(icon_names[i], "mail-unread-symbolic") == 0 ||
            g_strcmp0(icon_names[i], "dialog-information-symbolic") == 0) {
            for (guint r = 0; roots[r] != NULL; r++) {
                char *path = g_strdup_printf("%s/status/notification-symbolic.svg", roots[r]);
                if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
                g_free(path);
                path = g_strdup_printf("%s/status/notification-new-symbolic.svg", roots[r]);
                if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
                g_free(path);
            }
        }
    }

    return NULL;
}

static void set_icon_from_candidates(GtkWidget *image, const char * const *icon_names) {
    char *local_path = find_axia_icon_path(icon_names);
    if (local_path != NULL) {
        gtk_image_set_from_file(GTK_IMAGE(image), local_path);
        gtk_image_set_pixel_size(GTK_IMAGE(image), 16);
        g_free(local_path);
        return;
    }

    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    const char *selected = "applications-system-symbolic";

    if (theme != NULL && icon_names != NULL) {
        for (guint i = 0; icon_names[i] != NULL; i++) {
            if (gtk_icon_theme_has_icon(theme, icon_names[i])) {
                selected = icon_names[i];
                break;
            }
        }
    }

    gtk_image_set_from_icon_name(GTK_IMAGE(image), selected);
    gtk_image_set_pixel_size(GTK_IMAGE(image), 16);
}

static gboolean parse_bluetooth_state(gboolean *powered_out) {
    char *stdout_text = NULL;
    if (!run_command_capture("bluetoothctl show", &stdout_text) || stdout_text == NULL) return FALSE;

    *powered_out = g_strstr_len(stdout_text, -1, "Powered: yes") != NULL;
    g_free(stdout_text);
    return TRUE;
}

static gboolean update_bluetooth_button(gpointer data) {
    ShellState *state = data;
    if (state->bluetooth_button == NULL || state->bluetooth_icon == NULL) return G_SOURCE_REMOVE;

    gboolean powered = FALSE;
    const char *tooltip = "Bluetooth";
    const char *icons_on[] = { "bluetooth-active-symbolic", "bluetooth-symbolic", NULL };
    const char *icons_off[] = { "bluetooth-disabled-symbolic", "bluetooth-symbolic", "network-wireless-disabled-symbolic", NULL };

    if (parse_bluetooth_state(&powered)) {
        tooltip = powered ? "Bluetooth ligado" : "Bluetooth desligado";
        set_icon_from_candidates(state->bluetooth_icon, powered ? icons_on : icons_off);
    } else {
        set_icon_from_candidates(state->bluetooth_icon, icons_on);
    }

    gtk_widget_set_tooltip_text(state->bluetooth_button, tooltip);
    return G_SOURCE_CONTINUE;
}

typedef enum {
    NETWORK_STATE_OFFLINE,
    NETWORK_STATE_WIFI,
    NETWORK_STATE_ETHERNET,
} NetworkState;

static gboolean parse_network_state(NetworkState *state_out) {
    char *stdout_text = NULL;
    if (!run_command_capture("nmcli -t -f TYPE,STATE device status", &stdout_text) || stdout_text == NULL) return FALSE;

    NetworkState result = NETWORK_STATE_OFFLINE;
    gchar **lines = g_strsplit(stdout_text, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        if (g_str_has_prefix(lines[i], "wifi:connected")) {
            result = NETWORK_STATE_WIFI;
            break;
        }
        if (g_str_has_prefix(lines[i], "ethernet:connected")) {
            result = NETWORK_STATE_ETHERNET;
        }
    }

    g_strfreev(lines);
    g_free(stdout_text);
    *state_out = result;
    return TRUE;
}

static gboolean update_network_button(gpointer data) {
    ShellState *state = data;
    if (state->network_button == NULL || state->network_icon == NULL) return G_SOURCE_REMOVE;

    NetworkState network_state = NETWORK_STATE_OFFLINE;
    const char *tooltip = "Rede";
    const char *wifi_icons[] = { "network-wireless-signal-excellent-symbolic", "network-wireless-symbolic", NULL };
    const char *ethernet_icons[] = { "network-wired-symbolic", NULL };
    const char *offline_icons[] = { "network-offline-symbolic", "network-wireless-disconnected-symbolic", "network-wired-disconnected-symbolic", NULL };

    if (parse_network_state(&network_state)) {
        switch (network_state) {
            case NETWORK_STATE_WIFI:
                tooltip = "Wi-Fi conectado";
                set_icon_from_candidates(state->network_icon, wifi_icons);
                break;
            case NETWORK_STATE_ETHERNET:
                tooltip = "Ethernet conectada";
                set_icon_from_candidates(state->network_icon, ethernet_icons);
                break;
            case NETWORK_STATE_OFFLINE:
            default:
                tooltip = "Sem rede";
                set_icon_from_candidates(state->network_icon, offline_icons);
                break;
        }
    } else {
        set_icon_from_candidates(state->network_icon, offline_icons);
    }

    gtk_widget_set_tooltip_text(state->network_button, tooltip);
    return G_SOURCE_CONTINUE;
}

static gboolean parse_battery_state(int *capacity_out, gboolean *charging_out, gboolean *present_out) {
    char *path = NULL;
    if (!run_command_capture("sh -lc 'for d in /sys/class/power_supply/BAT*; do [ -e \"$d\" ] && { echo \"$d\"; break; }; done'", &path) || path == NULL) {
        *present_out = FALSE;
        return FALSE;
    }

    g_strstrip(path);
    if (*path == '\0') {
        g_free(path);
        *present_out = FALSE;
        return FALSE;
    }

    char *capacity_cmd = g_strdup_printf("cat '%s/capacity'", path);
    char *status_cmd = g_strdup_printf("cat '%s/status'", path);
    char *capacity_text = NULL;
    char *status_text = NULL;
    gboolean ok_capacity = run_command_capture(capacity_cmd, &capacity_text);
    gboolean ok_status = run_command_capture(status_cmd, &status_text);
    g_free(capacity_cmd);
    g_free(status_cmd);
    g_free(path);

    if (!ok_capacity || capacity_text == NULL || !ok_status || status_text == NULL) {
        g_free(capacity_text);
        g_free(status_text);
        *present_out = FALSE;
        return FALSE;
    }

    *capacity_out = CLAMP((int)g_ascii_strtoll(capacity_text, NULL, 10), 0, 100);
    *charging_out = g_strrstr(status_text, "Charging") != NULL;
    *present_out = TRUE;

    g_free(capacity_text);
    g_free(status_text);
    return TRUE;
}

static gboolean update_battery_button(gpointer data) {
    ShellState *state = data;
    if (state->battery_button == NULL || state->battery_icon == NULL) return G_SOURCE_REMOVE;

    int capacity = 0;
    gboolean charging = FALSE;
    gboolean present = FALSE;
    parse_battery_state(&capacity, &charging, &present);

    gtk_widget_set_visible(state->battery_button, present);
    if (!present) return G_SOURCE_CONTINUE;

    gchar *tooltip = NULL;
    const char * const *icons = NULL;
    if (charging) {
        if (capacity >= 95) {
            static const char * const tmp[] = { "battery-level-100-charging-symbolic", "battery-full-charging-symbolic", "battery-good-charging-symbolic", NULL };
            icons = tmp;
        } else if (capacity >= 65) {
            static const char * const tmp[] = { "battery-level-80-charging-symbolic", "battery-good-charging-symbolic", NULL };
            icons = tmp;
        } else if (capacity >= 35) {
            static const char * const tmp[] = { "battery-level-50-charging-symbolic", "battery-medium-charging-symbolic", NULL };
            icons = tmp;
        } else {
            static const char * const tmp[] = { "battery-level-20-charging-symbolic", "battery-low-charging-symbolic", NULL };
            icons = tmp;
        }
    } else {
        if (capacity >= 95) {
            static const char * const tmp[] = { "battery-level-100-symbolic", "battery-full-symbolic", "battery-good-symbolic", NULL };
            icons = tmp;
        } else if (capacity >= 65) {
            static const char * const tmp[] = { "battery-level-80-symbolic", "battery-good-symbolic", NULL };
            icons = tmp;
        } else if (capacity >= 35) {
            static const char * const tmp[] = { "battery-level-50-symbolic", "battery-medium-symbolic", NULL };
            icons = tmp;
        } else {
            static const char * const tmp[] = { "battery-level-20-symbolic", "battery-caution-symbolic", "battery-low-symbolic", NULL };
            icons = tmp;
        }
    }

    tooltip = charging
        ? g_strdup_printf("Bateria carregando: %d%%", capacity)
        : g_strdup_printf("Bateria: %d%%", capacity);
    if (icons == NULL) {
        static const char * const fallback_icons[] = { "battery-missing-symbolic", NULL };
        icons = fallback_icons;
    }
    set_icon_from_candidates(state->battery_icon, icons);
    gtk_widget_set_tooltip_text(state->battery_button, tooltip);
    g_free(tooltip);
    return G_SOURCE_CONTINUE;
}

static void toggle_audio(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;
    if (spawn_shell_command("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")) {
        update_audio_label(state);
    }
}

static void handle_activation_token_done(
    void *data,
    struct xdg_activation_token_v1 *token,
    const char *token_text
) {
    SpawnCommandRequest *request = data;
    const char *env_pairs[] = {
        "XDG_ACTIVATION_TOKEN", token_text,
        "DESKTOP_STARTUP_ID", token_text,
        NULL,
    };

    if (token_text != NULL && token_text[0] != '\0') {
        spawn_shell_command_with_env(request->command, env_pairs);
    } else {
        spawn_shell_command(request->command);
    }

    xdg_activation_token_v1_destroy(token);
    spawn_command_request_free(request);
}

static const struct xdg_activation_token_v1_listener activation_token_listener = {
    .done = handle_activation_token_done,
};

static void spawn_shell_command_activated(ShellState *state, const char *command) {
    if (state == NULL || command == NULL || *command == '\0') return;

    if (state->xdg_activation == NULL) {
        spawn_shell_command(command);
        return;
    }

    struct xdg_activation_token_v1 *token = xdg_activation_v1_get_activation_token(state->xdg_activation);
    if (token == NULL) {
        spawn_shell_command(command);
        return;
    }

    SpawnCommandRequest *request = g_new0(SpawnCommandRequest, 1);
    request->owner = state;
    request->command = g_strdup(command);

    struct wl_surface *wl_surface = shell_wayland_surface(state);
    if (wl_surface != NULL) xdg_activation_token_v1_set_surface(token, wl_surface);
    xdg_activation_token_v1_set_app_id(token, "org.axia.shellv2");
    xdg_activation_token_v1_add_listener(token, &activation_token_listener, request);
    xdg_activation_token_v1_commit(token);
    if (state->wl_display != NULL) wl_display_roundtrip(state->wl_display);
}

static void send_test_notification(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;

    const char *cmd = g_getenv("AXIA_V2_NOTIFICATIONS_CMD");
    if (cmd != NULL && *cmd != '\0') {
        spawn_shell_command_activated(state, cmd);
        return;
    }

    char *notify_send = g_find_program_in_path("notify-send");
    if (notify_send != NULL) {
        spawn_shell_command_activated(state, "notify-send 'Axia Shell V2' 'Canal de notificacoes conectado.'");
        g_free(notify_send);
        return;
    }

    g_print("axia-shell-v2: notifications requested\n");
}

static void open_launcher(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;

    const char *cmd = g_getenv("AXIA_V2_LAUNCHER_CMD");
    if (cmd != NULL && *cmd != '\0') {
        spawn_shell_command_activated(state, cmd);
        return;
    }

    if (g_file_test("shell-v2/scripts/run-axia-launcher.sh", G_FILE_TEST_IS_EXECUTABLE)) {
        spawn_shell_command_activated(state, "./shell-v2/scripts/run-axia-launcher.sh");
        return;
    }

    char *launcher = g_find_program_in_path("axia-launcher");
    if (launcher != NULL) {
        spawn_shell_command_activated(state, launcher);
        g_free(launcher);
        return;
    }

    g_print("axia-shell-v2: launcher requested\n");
}

static GtkWidget *build_button(const char *label, const char *css_class, GCallback callback, gpointer data) {
    GtkWidget *button = gtk_button_new_with_label(label);
    gtk_widget_add_css_class(button, "bar-button");
    if (css_class != NULL) gtk_widget_add_css_class(button, css_class);
    gtk_widget_set_focusable(button, FALSE);
    g_signal_connect(button, "clicked", callback, data);
    return button;
}

static GtkWidget *build_shell_icon(const char * const *icon_names) {
    char *local_path = find_axia_icon_path(icon_names);
    if (local_path != NULL) {
        GtkWidget *icon = gtk_image_new_from_file(local_path);
        gtk_image_set_pixel_size(GTK_IMAGE(icon), 16);
        gtk_widget_add_css_class(icon, "bar-icon");
        g_free(local_path);
        return icon;
    }

    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    const char *selected = "applications-system-symbolic";

    if (theme != NULL && icon_names != NULL) {
        for (guint i = 0; icon_names[i] != NULL; i++) {
            if (gtk_icon_theme_has_icon(theme, icon_names[i])) {
                selected = icon_names[i];
                break;
            }
        }
    }

    GtkWidget *icon = gtk_image_new_from_icon_name(selected);
    gtk_image_set_pixel_size(GTK_IMAGE(icon), 16);
    gtk_widget_add_css_class(icon, "bar-icon");
    return icon;
}

static GtkWidget *build_icon_button(const char *icon_name, const char *tooltip, GCallback callback, gpointer data) {
    const char *icons[] = { icon_name, "applications-system-symbolic", NULL };
    GtkWidget *button = gtk_button_new();
    gtk_widget_add_css_class(button, "bar-button");
    gtk_widget_add_css_class(button, "icon-button");
    gtk_widget_set_focusable(button, FALSE);
    if (tooltip != NULL) gtk_widget_set_tooltip_text(button, tooltip);

    GtkWidget *icon = build_shell_icon(icons);
    gtk_button_set_child(GTK_BUTTON(button), icon);
    g_signal_connect(button, "clicked", callback, data);
    return button;
}

static GtkWidget *build_menu_button(const char *label, const char *css_class) {
    GtkWidget *button = gtk_menu_button_new();
    gtk_widget_add_css_class(button, "bar-button");
    if (css_class != NULL) gtk_widget_add_css_class(button, css_class);
    gtk_widget_set_focusable(button, FALSE);
    gtk_menu_button_set_has_frame(GTK_MENU_BUTTON(button), FALSE);
    gtk_menu_button_set_always_show_arrow(GTK_MENU_BUTTON(button), FALSE);
    gtk_menu_button_set_can_shrink(GTK_MENU_BUTTON(button), TRUE);

    GtkWidget *child = gtk_label_new(label);
    gtk_widget_add_css_class(child, "menu-button-label");
    gtk_menu_button_set_child(GTK_MENU_BUTTON(button), child);
    return button;
}

static GtkWidget *build_menu_icon_button(const char *icon_name, const char *tooltip, const char *css_class) {
    const char *icons[] = { icon_name, "applications-system-symbolic", NULL };
    GtkWidget *button = gtk_menu_button_new();
    gtk_widget_add_css_class(button, "bar-button");
    gtk_widget_add_css_class(button, "icon-button");
    if (css_class != NULL) gtk_widget_add_css_class(button, css_class);
    gtk_widget_set_focusable(button, FALSE);
    gtk_menu_button_set_has_frame(GTK_MENU_BUTTON(button), FALSE);
    gtk_menu_button_set_always_show_arrow(GTK_MENU_BUTTON(button), FALSE);
    gtk_menu_button_set_can_shrink(GTK_MENU_BUTTON(button), TRUE);
    if (tooltip != NULL) gtk_widget_set_tooltip_text(button, tooltip);

    GtkWidget *icon = build_shell_icon(icons);
    gtk_menu_button_set_child(GTK_MENU_BUTTON(button), icon);
    return button;
}

static void run_shell_action(GtkButton *button, gpointer user_data) {
    (void)button;
    const char *command = user_data;
    spawn_shell_command(command);
}

static const char *get_settings_command(void) {
    static char *cached = NULL;
    if (cached != NULL) return cached;

    const char *env = g_getenv("AXIA_V2_SETTINGS_CMD");
    if (env != NULL && *env != '\0') {
        cached = g_strdup(env);
        return cached;
    }

    if (g_file_test("shell-v2/scripts/run-axia-settings.sh", G_FILE_TEST_IS_EXECUTABLE)) {
        cached = g_strdup("./shell-v2/scripts/run-axia-settings.sh");
        return cached;
    }

    char *bin = g_find_program_in_path("axia-settings");
    if (bin != NULL) {
        cached = bin;
        return cached;
    }

    cached = g_strdup("axia-settings");
    return cached;
}

static const char *get_power_command(void) {
    static char *cached = NULL;
    if (cached != NULL) return cached;

    const char *env = g_getenv("AXIA_V2_POWER_CMD");
    if (env != NULL && *env != '\0') {
        cached = g_strdup(env);
        return cached;
    }

    if (g_file_test("zig-out/shell-v2/axia-power", G_FILE_TEST_IS_EXECUTABLE)) {
        cached = g_strdup("./zig-out/shell-v2/axia-power");
        return cached;
    }

    if (g_file_test("shell-v2/scripts/run-axia-power.sh", G_FILE_TEST_IS_EXECUTABLE)) {
        cached = g_strdup("./shell-v2/scripts/run-axia-power.sh");
        return cached;
    }

    char *bin = g_find_program_in_path("axia-power");
    if (bin != NULL) {
        cached = bin;
        return cached;
    }

    cached = g_strdup("axia-power");
    return cached;
}

static void open_workspaces(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;

    const char *cmd = g_getenv("AXIA_V2_WORKSPACES_CMD");
    if (cmd != NULL && *cmd != '\0') {
        spawn_shell_command_activated(state, cmd);
        return;
    }

    if (g_file_test("zig-out/bin/axia-settings", G_FILE_TEST_IS_EXECUTABLE)) {
        spawn_shell_command_activated(state, "./zig-out/bin/axia-settings workspaces");
        return;
    }

    char *settings_bin = g_find_program_in_path("axia-settings");
    if (settings_bin != NULL) {
        char *command = g_strdup_printf("%s workspaces", settings_bin);
        spawn_shell_command_activated(state, command);
        g_free(command);
        g_free(settings_bin);
        return;
    }

    spawn_shell_command_activated(state, get_settings_command());
}

static void hide_power_window(ShellState *state) {
    if (state == NULL || state->power_window == NULL) return;
    gtk_widget_set_visible(state->power_window, FALSE);
}

static void open_settings(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;
    hide_power_window(state);
    spawn_shell_command_activated(state, get_settings_command());
}

static void open_bluetooth(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;
    hide_power_window(state);

    const char *cmd = g_getenv("AXIA_V2_BLUETOOTH_CMD");
    if (cmd != NULL && *cmd != '\0') {
        spawn_shell_command_activated(state, cmd);
        return;
    }

    char *blueman = g_find_program_in_path("blueman-manager");
    if (blueman != NULL) {
        spawn_shell_command_activated(state, blueman);
        g_free(blueman);
        return;
    }

    if (g_file_test("zig-out/bin/axia-settings", G_FILE_TEST_IS_EXECUTABLE)) {
        spawn_shell_command_activated(state, "./zig-out/bin/axia-settings bluetooth");
        return;
    }

    spawn_shell_command_activated(state, get_settings_command());
}

static void open_network(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;
    hide_power_window(state);

    const char *cmd = g_getenv("AXIA_V2_NETWORK_CMD");
    if (cmd != NULL && *cmd != '\0') {
        spawn_shell_command_activated(state, cmd);
        return;
    }

    if (g_file_test("zig-out/bin/axia-settings", G_FILE_TEST_IS_EXECUTABLE)) {
        spawn_shell_command_activated(state, "./zig-out/bin/axia-settings network");
        return;
    }

    char *settings_bin = g_find_program_in_path("axia-settings");
    if (settings_bin != NULL) {
        char *command = g_strdup_printf("%s network", settings_bin);
        spawn_shell_command_activated(state, command);
        g_free(command);
        g_free(settings_bin);
        return;
    }

    spawn_shell_command_activated(state, get_settings_command());
}

static void suspend_session(GtkButton *button, gpointer user_data) {
    ShellState *state = user_data;
    hide_power_window(state);
    run_shell_action(button, "systemctl suspend");
}

static void lock_session(GtkButton *button, gpointer user_data) {
    ShellState *state = user_data;
    hide_power_window(state);
    run_shell_action(button, "loginctl lock-session");
}

static void logout_session(GtkButton *button, gpointer user_data) {
    ShellState *state = user_data;
    hide_power_window(state);
    run_shell_action(button, "loginctl terminate-session \"$XDG_SESSION_ID\"");
}

static void reboot_session(GtkButton *button, gpointer user_data) {
    ShellState *state = user_data;
    hide_power_window(state);
    run_shell_action(button, "systemctl reboot");
}

static void shutdown_session(GtkButton *button, gpointer user_data) {
    ShellState *state = user_data;
    hide_power_window(state);
    run_shell_action(button, "systemctl poweroff");
}

static GtkWidget *build_power_menu_content(ShellState *state) {
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(content, "power-menu-frame");
    gtk_widget_add_css_class(content, "power-popover");
    gtk_widget_add_css_class(content, "power-popover-content");
    gtk_widget_set_margin_start(content, 10);
    gtk_widget_set_margin_end(content, 10);
    gtk_widget_set_margin_top(content, 10);
    gtk_widget_set_margin_bottom(content, 10);

    GtkWidget *settings = gtk_button_new();
    gtk_widget_add_css_class(settings, "session-row");
    gtk_widget_set_focusable(settings, FALSE);
    g_signal_connect(settings, "clicked", G_CALLBACK(open_settings), state);

    GtkWidget *settings_label = gtk_label_new("Configurações...");
    gtk_widget_add_css_class(settings_label, "session-row-text");
    gtk_label_set_xalign(GTK_LABEL(settings_label), 0.0f);
    gtk_button_set_child(GTK_BUTTON(settings), settings_label);
    gtk_box_append(GTK_BOX(content), settings);

    GtkWidget *separator_top = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_add_css_class(separator_top, "power-separator");
    gtk_box_append(GTK_BOX(content), separator_top);

    GtkWidget *lock = gtk_button_new();
    gtk_widget_add_css_class(lock, "session-row");
    gtk_widget_set_focusable(lock, FALSE);
    g_signal_connect(lock, "clicked", G_CALLBACK(lock_session), state);

    GtkWidget *lock_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *lock_left = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_hexpand(lock_left, TRUE);
    GtkWidget *lock_icon = build_shell_icon((const char * const[]) {
        "system-lock-screen-symbolic",
        "changes-prevent-symbolic",
        "changes-allow-symbolic",
        NULL,
    });
    GtkWidget *lock_label = gtk_label_new("Bloquear Tela");
    gtk_widget_add_css_class(lock_label, "session-row-text");
    gtk_label_set_xalign(GTK_LABEL(lock_label), 0.0f);
    gtk_box_append(GTK_BOX(lock_left), lock_icon);
    gtk_box_append(GTK_BOX(lock_left), lock_label);
    GtkWidget *lock_shortcut = gtk_label_new("Super + Esc");
    gtk_widget_add_css_class(lock_shortcut, "session-shortcut");
    gtk_label_set_xalign(GTK_LABEL(lock_shortcut), 1.0f);
    gtk_box_append(GTK_BOX(lock_box), lock_left);
    gtk_box_append(GTK_BOX(lock_box), lock_shortcut);
    gtk_button_set_child(GTK_BUTTON(lock), lock_box);
    gtk_box_append(GTK_BOX(content), lock);

    GtkWidget *logout = gtk_button_new();
    gtk_widget_add_css_class(logout, "session-row");
    gtk_widget_set_focusable(logout, FALSE);
    g_signal_connect(logout, "clicked", G_CALLBACK(logout_session), state);

    GtkWidget *logout_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *logout_left = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_hexpand(logout_left, TRUE);
    GtkWidget *logout_icon = build_shell_icon((const char * const[]) {
        "system-log-out-symbolic",
        "application-exit-symbolic",
        NULL,
    });
    GtkWidget *logout_label = gtk_label_new("Sair");
    gtk_widget_add_css_class(logout_label, "session-row-text");
    gtk_label_set_xalign(GTK_LABEL(logout_label), 0.0f);
    gtk_box_append(GTK_BOX(logout_left), logout_icon);
    gtk_box_append(GTK_BOX(logout_left), logout_label);
    GtkWidget *logout_shortcut = gtk_label_new("Super + Shift + Esc");
    gtk_widget_add_css_class(logout_shortcut, "session-shortcut");
    gtk_label_set_xalign(GTK_LABEL(logout_shortcut), 1.0f);
    gtk_box_append(GTK_BOX(logout_box), logout_left);
    gtk_box_append(GTK_BOX(logout_box), logout_shortcut);
    gtk_button_set_child(GTK_BUTTON(logout), logout_box);
    gtk_box_append(GTK_BOX(content), logout);

    GtkWidget *separator_bottom = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_add_css_class(separator_bottom, "power-separator");
    gtk_box_append(GTK_BOX(content), separator_bottom);

    GtkWidget *power_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 22);
    gtk_widget_add_css_class(power_row, "power-icon-row");
    gtk_widget_set_halign(power_row, GTK_ALIGN_CENTER);

    GtkWidget *suspend = gtk_button_new();
    gtk_widget_add_css_class(suspend, "power-icon-action");
    gtk_widget_set_focusable(suspend, FALSE);
    gtk_widget_set_tooltip_text(suspend, "Suspender");
    gtk_button_set_child(GTK_BUTTON(suspend), build_shell_icon((const char * const[]) {
        "system-suspend-symbolic",
        "media-playback-pause-symbolic",
        NULL,
    }));
    g_signal_connect(suspend, "clicked", G_CALLBACK(suspend_session), state);

    GtkWidget *reboot = gtk_button_new();
    gtk_widget_add_css_class(reboot, "power-icon-action");
    gtk_widget_set_focusable(reboot, FALSE);
    gtk_widget_set_tooltip_text(reboot, "Reiniciar");
    gtk_button_set_child(GTK_BUTTON(reboot), build_shell_icon((const char * const[]) {
        "system-reboot-symbolic",
        "view-refresh-symbolic",
        NULL,
    }));
    g_signal_connect(reboot, "clicked", G_CALLBACK(reboot_session), state);

    GtkWidget *poweroff = gtk_button_new();
    gtk_widget_add_css_class(poweroff, "power-icon-action");
    gtk_widget_add_css_class(poweroff, "power-danger");
    gtk_widget_set_focusable(poweroff, FALSE);
    gtk_widget_set_tooltip_text(poweroff, "Desligar");
    gtk_button_set_child(GTK_BUTTON(poweroff), build_shell_icon((const char * const[]) {
        "system-shutdown-symbolic",
        "system-log-out-symbolic",
        NULL,
    }));
    g_signal_connect(poweroff, "clicked", G_CALLBACK(shutdown_session), state);

    gtk_box_append(GTK_BOX(power_row), suspend);
    gtk_box_append(GTK_BOX(power_row), reboot);
    gtk_box_append(GTK_BOX(power_row), poweroff);
    gtk_box_append(GTK_BOX(content), power_row);

    return content;
}

static void ensure_power_window(ShellState *state) {
    if (state == NULL || state->app == NULL || state->power_window != NULL) return;

    GtkWidget *window = gtk_application_window_new(state->app);
    gtk_window_set_title(GTK_WINDOW(window), "Axia Power Menu");
    gtk_window_set_default_size(GTK_WINDOW(window), 340, -1);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_hide_on_close(GTK_WINDOW(window), TRUE);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(root, "power-menu-root");
    gtk_window_set_child(GTK_WINDOW(window), root);
    gtk_box_append(GTK_BOX(root), build_power_menu_content(state));

    if (gtk_layer_is_supported()) {
        gtk_layer_init_for_window(GTK_WINDOW(window));
        gtk_layer_set_namespace(GTK_WINDOW(window), "axia-power-v2");
        gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_OVERLAY);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, 44);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, 10);
        gtk_layer_set_keyboard_mode(GTK_WINDOW(window), GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
        gtk_layer_set_respect_close(GTK_WINDOW(window), TRUE);
    }

    state->power_window = window;
}

static void on_power_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    ShellState *state = user_data;
    hide_power_window(state);
    const char *command = get_power_command();
    if (command != NULL && g_str_has_prefix(command, "./zig-out/")) {
        spawn_program(command);
        return;
    }
    spawn_shell_command_activated(state, command);
}

static void clear_box(GtkWidget *box) {
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child != NULL) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(box), child);
        child = next;
    }
}

static char *window_label_text(const ToplevelItem *item) {
    const char *source = NULL;
    if (item->title != NULL && item->title[0] != '\0') {
        source = item->title;
    } else if (item->app_id != NULL && item->app_id[0] != '\0') {
        source = item->app_id;
    } else {
        source = "Janela";
    }

    glong length = g_utf8_strlen(source, -1);
    if (length <= 18) return g_strdup(source);

    const char *cut = g_utf8_offset_to_pointer(source, 17);
    char *prefix = g_strndup(source, cut - source);
    char *result = g_strconcat(prefix, "…", NULL);
    g_free(prefix);
    return result;
}

static char *normalize_icon_candidate(const char *raw) {
    if (raw == NULL || *raw == '\0') return NULL;

    char *copy = g_ascii_strdown(raw, -1);
    for (char *cursor = copy; *cursor != '\0'; cursor++) {
        if (*cursor == '.' || *cursor == '_' || *cursor == ' ' || *cursor == '/') {
            *cursor = '-';
        }
    }
    return copy;
}

static char *desktop_icon_name_from_app_info(GtkWidget *widget, GDesktopAppInfo *app_info) {
    if (app_info == NULL) return NULL;

    GIcon *icon = g_app_info_get_icon(G_APP_INFO(app_info));
    if (icon == NULL || !G_IS_THEMED_ICON(icon)) return NULL;

    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gtk_widget_get_display(widget));
    const gchar * const *names = g_themed_icon_get_names(G_THEMED_ICON(icon));
    for (guint i = 0; names != NULL && names[i] != NULL; i++) {
        if (gtk_icon_theme_has_icon(theme, names[i])) return g_strdup(names[i]);
    }

    char *icon_string = g_icon_to_string(icon);
    if (icon_string != NULL && gtk_icon_theme_has_icon(theme, icon_string)) return icon_string;
    g_free(icon_string);
    return NULL;
}

static char *desktop_icon_name_from_id(GtkWidget *widget, const char *desktop_id) {
    if (desktop_id == NULL || *desktop_id == '\0') return NULL;
    GDesktopAppInfo *info = g_desktop_app_info_new(desktop_id);
    if (info == NULL) return NULL;

    char *icon_name = desktop_icon_name_from_app_info(widget, info);
    g_object_unref(info);
    return icon_name;
}

static char *desktop_icon_name_from_search(GtkWidget *widget, const char *query) {
    if (query == NULL || *query == '\0') return NULL;

    gchar ***search = g_desktop_app_info_search(query);
    if (search == NULL) return NULL;

    char *resolved = NULL;
    for (guint i = 0; search[i] != NULL && resolved == NULL; i++) {
        for (guint j = 0; search[i][j] != NULL && resolved == NULL; j++) {
            resolved = desktop_icon_name_from_id(widget, search[i][j]);
        }
    }
    for (guint i = 0; search[i] != NULL; i++) {
        g_strfreev(search[i]);
    }
    g_free(search);
    return resolved;
}

static const char *fallback_icon_name_for_item(const ToplevelItem *item) {
    const char *app_id = item->app_id != NULL ? item->app_id : "";
    const char *title = item->title != NULL ? item->title : "";

    if (g_strrstr(app_id, "files") != NULL || g_strrstr(app_id, "nautilus") != NULL || g_strrstr(title, "Arquivo") != NULL) {
        return "folder-symbolic";
    }
    if (g_strrstr(app_id, "launcher") != NULL || g_strrstr(app_id, "app-grid") != NULL) {
        return "view-app-grid-symbolic";
    }
    if (g_strrstr(app_id, "foot") != NULL || g_strrstr(app_id, "kitty") != NULL || g_strrstr(app_id, "terminal") != NULL) {
        return "utilities-terminal-symbolic";
    }
    if (g_strrstr(app_id, "code") != NULL || g_strrstr(app_id, "vscodium") != NULL || g_strrstr(app_id, "zed") != NULL) {
        return "applications-development-symbolic";
    }
    if (g_strrstr(app_id, "firefox") != NULL || g_strrstr(app_id, "chrom") != NULL || g_strrstr(app_id, "browser") != NULL) {
        return "internet-web-browser-symbolic";
    }
    return "application-x-executable-symbolic";
}

static char *resolve_toplevel_icon_name(GtkWidget *widget, const ToplevelItem *item) {
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gtk_widget_get_display(widget));

    const char *app_id = item->app_id != NULL ? item->app_id : NULL;
    char *normalized_app = normalize_icon_candidate(app_id);

    const char *tail_source = app_id;
    if (tail_source != NULL) {
        const char *dot_tail = strrchr(tail_source, '.');
        if (dot_tail != NULL && dot_tail[1] != '\0') tail_source = dot_tail + 1;
    }
    char *tail = tail_source != NULL ? g_strdup(tail_source) : NULL;
    char *normalized_tail = normalize_icon_candidate(tail);
    char *normalized_title = normalize_icon_candidate(item->title);
    const char *fallback = fallback_icon_name_for_item(item);
    char *desktop_icon = NULL;

    const char *desktop_candidates[] = {
        app_id,
        normalized_app,
        tail,
        normalized_tail,
        NULL,
    };

    for (guint i = 0; desktop_candidates[i] != NULL && desktop_icon == NULL; i++) {
        const char *candidate = desktop_candidates[i];
        if (candidate == NULL || candidate[0] == '\0') continue;

        if (g_str_has_suffix(candidate, ".desktop")) {
            desktop_icon = desktop_icon_name_from_id(widget, candidate);
        } else {
            char *desktop_id = g_strdup_printf("%s.desktop", candidate);
            desktop_icon = desktop_icon_name_from_id(widget, desktop_id);
            g_free(desktop_id);
        }
    }

    if (desktop_icon == NULL) {
        desktop_icon = desktop_icon_name_from_search(widget, app_id);
    }
    if (desktop_icon == NULL) {
        desktop_icon = desktop_icon_name_from_search(widget, item->title);
    }

    if (desktop_icon != NULL && gtk_icon_theme_has_icon(theme, desktop_icon)) {
        g_free(normalized_app);
        g_free(tail);
        g_free(normalized_tail);
        g_free(normalized_title);
        return desktop_icon;
    }
    g_free(desktop_icon);

    const char *candidates[] = {
        app_id,
        normalized_app,
        tail,
        normalized_tail,
        normalized_title,
        fallback,
        "application-x-executable-symbolic",
        NULL,
    };

    char *selected = NULL;
    for (guint i = 0; candidates[i] != NULL; i++) {
        if (candidates[i][0] == '\0') continue;
        if (gtk_icon_theme_has_icon(theme, candidates[i])) {
            selected = g_strdup(candidates[i]);
            break;
        }
    }

    g_free(normalized_app);
    g_free(tail);
    g_free(normalized_tail);
    g_free(normalized_title);

    if (selected != NULL) return selected;
    return g_strdup("application-x-executable-symbolic");
}

static GtkWidget *build_toplevel_button_child(GtkWidget *button, const ToplevelItem *item) {
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(content, "window-button-content");

    char *icon_name = resolve_toplevel_icon_name(button, item);
    GtkWidget *icon = gtk_image_new_from_icon_name(icon_name);
    gtk_widget_add_css_class(icon, "window-icon");
    gtk_image_set_pixel_size(GTK_IMAGE(icon), 16);
    g_free(icon_name);

    char *label_text = window_label_text(item);
    GtkWidget *label = gtk_label_new(label_text);
    gtk_widget_add_css_class(label, "window-title");
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 14);
    gtk_widget_set_hexpand(label, TRUE);
    g_free(label_text);

    GtkWidget *indicator = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(indicator, "window-indicator");
    if (item->activated && !item->minimized) {
        gtk_widget_add_css_class(indicator, "is-active");
    } else if (item->fullscreen) {
        gtk_widget_add_css_class(indicator, "is-fullscreen");
    } else if (item->minimized) {
        gtk_widget_add_css_class(indicator, "is-minimized");
    }

    gtk_box_append(GTK_BOX(content), icon);
    gtk_box_append(GTK_BOX(content), label);
    gtk_box_append(GTK_BOX(content), indicator);
    return content;
}

static void toplevel_action_payload_free(gpointer data, GClosure *closure) {
    (void)closure;
    g_free(data);
}

static void on_workspace_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    WorkspaceItem *item = user_data;
    if (item->handle == NULL || item->owner->workspace_manager == NULL) return;
    ext_workspace_handle_v1_activate(item->handle);
    ext_workspace_manager_v1_commit(item->owner->workspace_manager);
    flush_wayland(item->owner);
}

static char *workspace_button_label(WorkspaceItem *item, guint index) {
    if (item->name != NULL && item->name[0] != '\0') return g_strdup(item->name);
    return g_strdup_printf("%u", index + 1);
}

static void refresh_workspace_ui(ShellState *state) {
    clear_box(state->workspace_box);

    if (state->protocols_disabled || !state->workspace_protocol_available) {
        GtkWidget *fallback = build_button("Areas de Trabalho", "nav-button", G_CALLBACK(open_workspaces), state);
        gtk_widget_set_tooltip_text(
            fallback,
            state->protocols_disabled
                ? "Protocolos da shell V2 foram desativados por AXIA_V2_DISABLE_SHELL_PROTOCOLS."
                : "ext-workspace-v1 indisponivel nesta sessao.");
        gtk_box_append(GTK_BOX(state->workspace_box), fallback);
        return;
    }

    if (!state->protocol_scan_complete && state->workspaces->len == 0) {
        GtkWidget *placeholder = gtk_label_new("Conectando areas...");
        gtk_widget_add_css_class(placeholder, "workspace-placeholder");
        gtk_box_append(GTK_BOX(state->workspace_box), placeholder);
        return;
    }

    if (state->workspaces->len == 0) {
        GtkWidget *fallback = build_button("Areas de Trabalho", "nav-button", G_CALLBACK(open_workspaces), state);
        gtk_widget_set_tooltip_text(fallback, "Nenhuma workspace publicada pelo compositor.");
        gtk_box_append(GTK_BOX(state->workspace_box), fallback);
        return;
    }

    for (guint i = 0; i < state->workspaces->len; i++) {
        WorkspaceItem *item = g_ptr_array_index(state->workspaces, i);
        char *label = workspace_button_label(item, i);
        GtkWidget *button = build_button(label, "workspace-button", G_CALLBACK(on_workspace_clicked), item);
        gboolean is_active = (item->state & EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE) != 0;
        gboolean is_urgent = (item->state & EXT_WORKSPACE_HANDLE_V1_STATE_URGENT) != 0;
        gboolean can_activate = (item->capabilities & EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE) != 0;

        if (is_active) gtk_widget_add_css_class(button, "is-active");
        if (is_urgent) gtk_widget_add_css_class(button, "is-urgent");
        gtk_widget_set_sensitive(button, can_activate || is_active);

        gtk_box_append(GTK_BOX(state->workspace_box), button);
        item->button = button;
        g_free(label);
    }
}

static void on_toplevel_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    ToplevelItem *item = user_data;
    if (item->handle == NULL || item->owner->wl_seat == NULL) return;

    if (item->minimized) zwlr_foreign_toplevel_handle_v1_unset_minimized(item->handle);
    zwlr_foreign_toplevel_handle_v1_activate(item->handle, item->owner->wl_seat);
    flush_wayland(item->owner);
}

static void close_toplevel_menu(GtkPopover *popover, ToplevelItem *item) {
    if (popover == NULL) return;
    if (item != NULL && item->popover == GTK_WIDGET(popover)) item->popover = NULL;
    gtk_popover_popdown(popover);
}

static void on_toplevel_popover_closed(GtkPopover *popover, gpointer user_data) {
    ToplevelItem *item = user_data;
    if (item != NULL && item->popover == GTK_WIDGET(popover)) item->popover = NULL;
    if (gtk_widget_get_parent(GTK_WIDGET(popover)) != NULL) gtk_widget_unparent(GTK_WIDGET(popover));
}

static void run_toplevel_action(GtkButton *button, gpointer user_data) {
    (void)button;
    ToplevelActionPayload *payload = user_data;
    ToplevelItem *item = payload->item;
    if (item == NULL || item->handle == NULL) return;

    switch (payload->action) {
        case TOPLEVEL_ACTION_ACTIVATE:
            if (item->minimized) zwlr_foreign_toplevel_handle_v1_unset_minimized(item->handle);
            if (item->owner->wl_seat != NULL) {
                zwlr_foreign_toplevel_handle_v1_activate(item->handle, item->owner->wl_seat);
            }
            break;
        case TOPLEVEL_ACTION_TOGGLE_MINIMIZED:
            if (item->minimized) {
                zwlr_foreign_toplevel_handle_v1_unset_minimized(item->handle);
                if (item->owner->wl_seat != NULL) {
                    zwlr_foreign_toplevel_handle_v1_activate(item->handle, item->owner->wl_seat);
                }
            } else {
                zwlr_foreign_toplevel_handle_v1_set_minimized(item->handle);
            }
            break;
        case TOPLEVEL_ACTION_TOGGLE_MAXIMIZED:
            if (item->maximized) {
                zwlr_foreign_toplevel_handle_v1_unset_maximized(item->handle);
            } else {
                zwlr_foreign_toplevel_handle_v1_set_maximized(item->handle);
            }
            break;
        case TOPLEVEL_ACTION_TOGGLE_FULLSCREEN:
            if (item->fullscreen) {
                zwlr_foreign_toplevel_handle_v1_unset_fullscreen(item->handle);
            } else {
                zwlr_foreign_toplevel_handle_v1_set_fullscreen(item->handle, NULL);
            }
            break;
        case TOPLEVEL_ACTION_CLOSE:
            zwlr_foreign_toplevel_handle_v1_close(item->handle);
            break;
    }

    flush_wayland(item->owner);
    close_toplevel_menu(payload->popover, item);
}

static GtkWidget *build_toplevel_menu_action(
    ToplevelItem *item,
    GtkPopover *popover,
    const char *label,
    ToplevelAction action,
    gboolean danger
) {
    ToplevelActionPayload *payload = g_new0(ToplevelActionPayload, 1);
    payload->item = item;
    payload->action = action;
    payload->popover = popover;

    GtkWidget *button = gtk_button_new_with_label(label);
    gtk_widget_add_css_class(button, "bar-button");
    gtk_widget_add_css_class(button, "window-action");
    if (danger) gtk_widget_add_css_class(button, "power-danger");
    gtk_widget_set_focusable(button, FALSE);
    gtk_widget_set_hexpand(button, TRUE);
    gtk_widget_set_halign(button, GTK_ALIGN_FILL);
    g_signal_connect_data(button, "clicked", G_CALLBACK(run_toplevel_action), payload, toplevel_action_payload_free, 0);
    return button;
}

static void show_toplevel_menu(ToplevelItem *item, GtkWidget *button, double x, double y) {
    if (item == NULL || button == NULL) return;

    if (item->popover != NULL) {
        close_toplevel_menu(GTK_POPOVER(item->popover), item);
    }

    GtkWidget *popover = gtk_popover_new();
    item->popover = popover;
    gtk_widget_add_css_class(popover, "window-popover");
    gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    gtk_popover_set_autohide(GTK_POPOVER(popover), TRUE);
    gtk_popover_set_offset(GTK_POPOVER(popover), 0, 8);
    gtk_widget_set_parent(popover, button);
    g_signal_connect(popover, "closed", G_CALLBACK(on_toplevel_popover_closed), item);

    GdkRectangle rect = {
        .x = (int)x,
        .y = (int)y,
        .width = 1,
        .height = 1,
    };
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), &rect);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(content, "window-popover-content");
    gtk_widget_set_margin_start(content, 10);
    gtk_widget_set_margin_end(content, 10);
    gtk_widget_set_margin_top(content, 10);
    gtk_widget_set_margin_bottom(content, 10);
    gtk_popover_set_child(GTK_POPOVER(popover), content);

    GtkWidget *title = gtk_label_new(item->title != NULL && item->title[0] != '\0' ? item->title : "Janela");
    gtk_widget_add_css_class(title, "popover-title");
    gtk_widget_add_css_class(title, "window-popover-title");
    gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
    gtk_box_append(GTK_BOX(content), title);

    GtkWidget *subtitle = gtk_label_new(item->app_id != NULL && item->app_id[0] != '\0' ? item->app_id : "Aplicativo");
    gtk_widget_add_css_class(subtitle, "window-popover-subtitle");
    gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0f);
    gtk_box_append(GTK_BOX(content), subtitle);

    gtk_box_append(
        GTK_BOX(content),
        build_toplevel_menu_action(
            item,
            GTK_POPOVER(popover),
            item->activated && !item->minimized ? "Janela ativa" : "Ativar",
            TOPLEVEL_ACTION_ACTIVATE,
            FALSE));
    gtk_box_append(
        GTK_BOX(content),
        build_toplevel_menu_action(
            item,
            GTK_POPOVER(popover),
            item->minimized ? "Restaurar" : "Minimizar",
            TOPLEVEL_ACTION_TOGGLE_MINIMIZED,
            FALSE));
    gtk_box_append(
        GTK_BOX(content),
        build_toplevel_menu_action(
            item,
            GTK_POPOVER(popover),
            item->maximized ? "Sair da maximizacao" : "Maximizar",
            TOPLEVEL_ACTION_TOGGLE_MAXIMIZED,
            FALSE));
    gtk_box_append(
        GTK_BOX(content),
        build_toplevel_menu_action(
            item,
            GTK_POPOVER(popover),
            item->fullscreen ? "Sair da tela cheia" : "Tela cheia",
            TOPLEVEL_ACTION_TOGGLE_FULLSCREEN,
            FALSE));
    gtk_box_append(
        GTK_BOX(content),
        build_toplevel_menu_action(
            item,
            GTK_POPOVER(popover),
            "Fechar",
            TOPLEVEL_ACTION_CLOSE,
            TRUE));

    gtk_popover_present(GTK_POPOVER(popover));
    gtk_popover_popup(GTK_POPOVER(popover));
}

static void on_toplevel_secondary_pressed(
    GtkGestureClick *gesture,
    int n_press,
    double x,
    double y,
    gpointer user_data
) {
    (void)n_press;
    ToplevelItem *item = user_data;
    GtkWidget *button = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    show_toplevel_menu(item, button, x, y);
}

static void refresh_toplevel_ui(ShellState *state) {
    for (guint i = 0; i < state->toplevels->len; i++) {
        ToplevelItem *item = g_ptr_array_index(state->toplevels, i);
        item->button = NULL;
        item->popover = NULL;
    }
    clear_box(state->window_box);

    if (state->protocols_disabled || !state->toplevel_protocol_available || state->toplevels->len == 0) {
        gtk_widget_set_visible(state->window_box, FALSE);
        return;
    }

    gtk_widget_set_visible(state->window_box, TRUE);

    for (guint i = 0; i < state->toplevels->len; i++) {
        ToplevelItem *item = g_ptr_array_index(state->toplevels, i);
        item->button = build_button("Janela", "window-button", G_CALLBACK(on_toplevel_clicked), item);
        gtk_widget_set_size_request(item->button, 92, -1);

        GtkGesture *secondary_click = gtk_gesture_click_new();
        gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(secondary_click), GDK_BUTTON_SECONDARY);
        gtk_widget_add_controller(item->button, GTK_EVENT_CONTROLLER(secondary_click));
        g_signal_connect(secondary_click, "pressed", G_CALLBACK(on_toplevel_secondary_pressed), item);

        gtk_button_set_child(GTK_BUTTON(item->button), build_toplevel_button_child(item->button, item));

        const char *tooltip = item->title != NULL && item->title[0] != '\0'
            ? item->title
            : (item->app_id != NULL && item->app_id[0] != '\0' ? item->app_id : "Janela");
        gtk_widget_set_tooltip_text(item->button, tooltip);

        if (item->activated && !item->minimized) {
            gtk_widget_add_css_class(item->button, "is-active");
        } else {
            gtk_widget_remove_css_class(item->button, "is-active");
        }

        if (item->minimized) {
            gtk_widget_add_css_class(item->button, "is-minimized");
        } else {
            gtk_widget_remove_css_class(item->button, "is-minimized");
        }

        gtk_box_append(GTK_BOX(state->window_box), item->button);
    }
}

static void workspace_group_capabilities(void *data, struct ext_workspace_group_handle_v1 *group, uint32_t capabilities) {
    (void)data;
    (void)group;
    (void)capabilities;
}

static void workspace_group_output_enter(void *data, struct ext_workspace_group_handle_v1 *group, struct wl_output *output) {
    (void)data;
    (void)group;
    (void)output;
}

static void workspace_group_output_leave(void *data, struct ext_workspace_group_handle_v1 *group, struct wl_output *output) {
    (void)data;
    (void)group;
    (void)output;
}

static void workspace_group_workspace_enter(void *data, struct ext_workspace_group_handle_v1 *group, struct ext_workspace_handle_v1 *workspace) {
    (void)data;
    (void)group;
    (void)workspace;
}

static void workspace_group_workspace_leave(void *data, struct ext_workspace_group_handle_v1 *group, struct ext_workspace_handle_v1 *workspace) {
    (void)data;
    (void)group;
    (void)workspace;
}

static void workspace_group_removed(void *data, struct ext_workspace_group_handle_v1 *group) {
    (void)data;
    ext_workspace_group_handle_v1_destroy(group);
}

static const struct ext_workspace_group_handle_v1_listener workspace_group_listener = {
    .capabilities = workspace_group_capabilities,
    .output_enter = workspace_group_output_enter,
    .output_leave = workspace_group_output_leave,
    .workspace_enter = workspace_group_workspace_enter,
    .workspace_leave = workspace_group_workspace_leave,
    .removed = workspace_group_removed,
};

static void workspace_name(void *data, struct ext_workspace_handle_v1 *workspace, const char *name) {
    (void)workspace;
    WorkspaceItem *item = data;
    g_free(item->name);
    item->name = g_strdup(name);
}

static void workspace_id(void *data, struct ext_workspace_handle_v1 *workspace, const char *id) {
    (void)data;
    (void)workspace;
    (void)id;
}

static void workspace_coordinates(void *data, struct ext_workspace_handle_v1 *workspace, struct wl_array *coords) {
    (void)data;
    (void)workspace;
    (void)coords;
}

static void workspace_state(void *data, struct ext_workspace_handle_v1 *workspace, uint32_t state_flags) {
    (void)workspace;
    WorkspaceItem *item = data;
    item->state = state_flags;
}

static void workspace_capabilities(void *data, struct ext_workspace_handle_v1 *workspace, uint32_t capabilities) {
    (void)workspace;
    WorkspaceItem *item = data;
    item->capabilities = capabilities;
}

static void workspace_removed(void *data, struct ext_workspace_handle_v1 *workspace) {
    WorkspaceItem *item = data;
    ShellState *state = item->owner;
    for (guint i = 0; i < state->workspaces->len; i++) {
        if (g_ptr_array_index(state->workspaces, i) == item) {
            item->handle = NULL;
            g_ptr_array_remove_index(state->workspaces, i);
            break;
        }
    }
    ext_workspace_handle_v1_destroy(workspace);
    refresh_workspace_ui(state);
}

static const struct ext_workspace_handle_v1_listener workspace_listener = {
    .id = workspace_id,
    .name = workspace_name,
    .coordinates = workspace_coordinates,
    .state = workspace_state,
    .capabilities = workspace_capabilities,
    .removed = workspace_removed,
};

static void workspace_manager_group(void *data, struct ext_workspace_manager_v1 *manager, struct ext_workspace_group_handle_v1 *group) {
    (void)data;
    (void)manager;
    ext_workspace_group_handle_v1_add_listener(group, &workspace_group_listener, NULL);
}

static void workspace_manager_workspace(void *data, struct ext_workspace_manager_v1 *manager, struct ext_workspace_handle_v1 *workspace) {
    (void)manager;
    ShellState *state = data;
    WorkspaceItem *item = g_new0(WorkspaceItem, 1);
    item->owner = state;
    item->handle = workspace;
    g_ptr_array_add(state->workspaces, item);
    ext_workspace_handle_v1_add_listener(workspace, &workspace_listener, item);
}

static void workspace_manager_done(void *data, struct ext_workspace_manager_v1 *manager) {
    (void)manager;
    ShellState *state = data;
    refresh_workspace_ui(state);
}

static void workspace_manager_finished(void *data, struct ext_workspace_manager_v1 *manager) {
    ShellState *state = data;
    if (state->workspace_manager == manager) state->workspace_manager = NULL;
}

static const struct ext_workspace_manager_v1_listener workspace_manager_listener = {
    .workspace_group = workspace_manager_group,
    .workspace = workspace_manager_workspace,
    .done = workspace_manager_done,
    .finished = workspace_manager_finished,
};

static void toplevel_title(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, const char *title) {
    (void)handle;
    ToplevelItem *item = data;
    g_free(item->title);
    item->title = g_strdup(title);
}

static void toplevel_app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, const char *app_id) {
    (void)handle;
    ToplevelItem *item = data;
    g_free(item->app_id);
    item->app_id = g_strdup(app_id);
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
    ToplevelItem *item = data;

    item->activated = FALSE;
    item->maximized = FALSE;
    item->minimized = FALSE;
    item->fullscreen = FALSE;

    uint32_t *state = NULL;
    wl_array_for_each(state, state_array) {
        switch (*state) {
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED:
                item->activated = TRUE;
                break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED:
                item->maximized = TRUE;
                break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED:
                item->minimized = TRUE;
                break;
            case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN:
                item->fullscreen = TRUE;
                break;
            default:
                break;
        }
    }
}

static void toplevel_done(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle) {
    (void)handle;
    ToplevelItem *item = data;
    refresh_toplevel_ui(item->owner);
}

static void toplevel_closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle) {
    ToplevelItem *item = data;
    ShellState *state = item->owner;
    for (guint i = 0; i < state->toplevels->len; i++) {
        if (g_ptr_array_index(state->toplevels, i) == item) {
            item->handle = NULL;
            g_ptr_array_remove_index(state->toplevels, i);
            break;
        }
    }
    zwlr_foreign_toplevel_handle_v1_destroy(handle);
    refresh_toplevel_ui(state);
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
    ShellState *state = data;
    ToplevelItem *item = g_new0(ToplevelItem, 1);
    item->owner = state;
    item->handle = handle;
    g_ptr_array_add(state->toplevels, item);
    zwlr_foreign_toplevel_handle_v1_add_listener(handle, &toplevel_listener, item);
}

static void toplevel_manager_finished(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager) {
    ShellState *state = data;
    if (state->toplevel_manager == manager) state->toplevel_manager = NULL;
}

static const struct zwlr_foreign_toplevel_manager_v1_listener toplevel_manager_listener = {
    .toplevel = toplevel_manager_toplevel,
    .finished = toplevel_manager_finished,
};

static void handle_registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    ShellState *state = data;

    if (g_strcmp0(interface, wl_seat_interface.name) == 0) {
        state->wl_seat = wl_registry_bind(registry, name, &wl_seat_interface, MIN(version, 5));
        return;
    }

    if (g_strcmp0(interface, ext_workspace_manager_v1_interface.name) == 0) {
        state->workspace_protocol_available = TRUE;
        state->workspace_manager = wl_registry_bind(registry, name, &ext_workspace_manager_v1_interface, 1);
        ext_workspace_manager_v1_add_listener(state->workspace_manager, &workspace_manager_listener, state);
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

static void handle_registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = handle_registry_global,
    .global_remove = handle_registry_remove,
};

static void initialize_protocols(ShellState *state) {
    if (state->protocols_disabled) {
        state->protocol_scan_complete = TRUE;
        refresh_workspace_ui(state);
        refresh_toplevel_ui(state);
        return;
    }

    state->wl_display = wl_display_connect(NULL);
    if (state->wl_display == NULL) {
        state->protocol_scan_complete = TRUE;
        refresh_workspace_ui(state);
        refresh_toplevel_ui(state);
        return;
    }

    state->registry = wl_display_get_registry(state->wl_display);
    wl_registry_add_listener(state->registry, &registry_listener, state);

    wl_display_roundtrip(state->wl_display);
    wl_display_roundtrip(state->wl_display);
    state->protocol_scan_complete = TRUE;

    refresh_workspace_ui(state);
    refresh_toplevel_ui(state);
}

static void activate(GApplication *app, gpointer user_data) {
    (void)user_data;

    GtkWidget *window = gtk_application_window_new(GTK_APPLICATION(app));
    GdkMonitor *monitor = preferred_monitor();
    GdkRectangle monitor_geometry = { 0 };
    if (monitor != NULL) gdk_monitor_get_geometry(monitor, &monitor_geometry);

    gtk_window_set_title(GTK_WINDOW(window), "Axia Shell V2");
    gtk_window_set_default_size(
        GTK_WINDOW(window),
        monitor_geometry.width > 0 ? monitor_geometry.width : 1366,
        44);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(root, "shell-root");
    gtk_widget_set_hexpand(root, TRUE);
    gtk_widget_set_halign(root, GTK_ALIGN_FILL);
    gtk_window_set_child(GTK_WINDOW(window), root);

    ShellState *state = g_new0(ShellState, 1);
    state->app = GTK_APPLICATION(app);
    state->window = window;
    state->protocols_disabled = shell_protocols_disabled();
    state->workspaces = g_ptr_array_new_with_free_func(workspace_item_free);
    state->toplevels = g_ptr_array_new_with_free_func(toplevel_item_free);

    GtkWidget *panel = gtk_center_box_new();
    gtk_widget_add_css_class(panel, "panel");
    gtk_widget_set_hexpand(panel, TRUE);
    gtk_widget_set_halign(panel, GTK_ALIGN_FILL);
    gtk_box_append(GTK_BOX(root), panel);

    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(left, "bar-group");
    gtk_widget_set_hexpand(left, TRUE);
    gtk_center_box_set_start_widget(GTK_CENTER_BOX(panel), left);

    GtkWidget *workspace_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(workspace_box, "workspace-strip");
    gtk_box_append(GTK_BOX(left), workspace_box);
    state->workspace_box = workspace_box;

    gtk_box_append(GTK_BOX(left), build_button("Aplicativos", "nav-button", G_CALLBACK(open_launcher), state));

    GtkWidget *center = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(center, "center-clock-wrap");
    gtk_widget_set_hexpand(center, TRUE);
    gtk_widget_set_halign(center, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(center, GTK_ALIGN_CENTER);
    gtk_center_box_set_center_widget(GTK_CENTER_BOX(panel), center);

    GtkWidget *right = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(right, "bar-group");
    gtk_widget_add_css_class(right, "right-strip");
    gtk_widget_set_hexpand(right, TRUE);
    gtk_widget_set_halign(right, GTK_ALIGN_END);
    gtk_center_box_set_end_widget(GTK_CENTER_BOX(panel), right);

    GtkWidget *clock = gtk_label_new("");
    gtk_widget_add_css_class(clock, "clock");
    gtk_box_append(GTK_BOX(center), clock);

    state->window_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(state->window_box, "window-strip");
    gtk_widget_set_halign(state->window_box, GTK_ALIGN_CENTER);
    gtk_widget_set_visible(state->window_box, FALSE);
    gtk_box_append(GTK_BOX(center), state->window_box);

    {
        const char *icons[] = {
            "bluetooth-active-symbolic",
            "bluetooth-symbolic",
            "preferences-system-bluetooth-symbolic",
            NULL,
        };
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "bar-button");
        gtk_widget_add_css_class(button, "icon-button");
        gtk_widget_set_focusable(button, FALSE);
        gtk_widget_set_tooltip_text(button, "Bluetooth");
        GtkWidget *icon = build_shell_icon(icons);
        gtk_button_set_child(GTK_BUTTON(button), icon);
        g_signal_connect(button, "clicked", G_CALLBACK(open_bluetooth), state);
        state->bluetooth_button = button;
        state->bluetooth_icon = icon;
        gtk_box_append(GTK_BOX(right), button);
    }

    GtkWidget *audio_button = gtk_button_new();
    gtk_widget_add_css_class(audio_button, "bar-button");
    gtk_widget_add_css_class(audio_button, "audio-button");
    gtk_widget_set_focusable(audio_button, FALSE);

    GtkWidget *audio_content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *audio_icon = build_shell_icon((const char * const[]) {
        "audio-volume-medium-symbolic",
        "audio-speakers-symbolic",
        "preferences-sound-symbolic",
        NULL,
    });
    GtkWidget *audio_label = gtk_label_new("0%");
    gtk_widget_add_css_class(audio_label, "audio-label");
    gtk_box_append(GTK_BOX(audio_content), audio_icon);
    gtk_box_append(GTK_BOX(audio_content), audio_label);
    gtk_button_set_child(GTK_BUTTON(audio_button), audio_content);
    g_signal_connect(audio_button, "clicked", G_CALLBACK(toggle_audio), state);

    {
        const char *icons[] = {
            "network-wireless-signal-excellent-symbolic",
            "network-wired-symbolic",
            "network-offline-symbolic",
            NULL,
        };
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "bar-button");
        gtk_widget_add_css_class(button, "icon-button");
        gtk_widget_set_focusable(button, FALSE);
        gtk_widget_set_tooltip_text(button, "Rede");
        GtkWidget *icon = build_shell_icon(icons);
        gtk_button_set_child(GTK_BUTTON(button), icon);
        g_signal_connect(button, "clicked", G_CALLBACK(open_network), state);
        state->network_button = button;
        state->network_icon = icon;
        gtk_box_append(GTK_BOX(right), button);
    }

    {
        const char *icons[] = {
            "battery-level-100-symbolic",
            "battery-full-symbolic",
            "battery-good-symbolic",
            NULL,
        };
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "bar-button");
        gtk_widget_add_css_class(button, "icon-button");
        gtk_widget_set_focusable(button, FALSE);
        gtk_widget_set_tooltip_text(button, "Bateria");
        GtkWidget *icon = build_shell_icon(icons);
        gtk_button_set_child(GTK_BUTTON(button), icon);
        g_signal_connect(button, "clicked", G_CALLBACK(open_settings), state);
        state->battery_button = button;
        state->battery_icon = icon;
        gtk_widget_set_visible(button, FALSE);
        gtk_box_append(GTK_BOX(right), button);
    }

    {
        const char *icons[] = {
            "notification-symbolic",
            "notification-new-symbolic",
            "notification-alert-symbolic",
            NULL,
        };
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "bar-button");
        gtk_widget_add_css_class(button, "icon-button");
        gtk_widget_set_focusable(button, FALSE);
        gtk_widget_set_tooltip_text(button, "Notificacoes");
        gtk_button_set_child(GTK_BUTTON(button), build_shell_icon(icons));
        g_signal_connect(button, "clicked", G_CALLBACK(send_test_notification), state);
        gtk_box_append(GTK_BOX(right), button);
    }

    gtk_box_append(GTK_BOX(right), audio_button);

    {
        const char *icons[] = {
            "system-shutdown-symbolic",
            "system-log-out-symbolic",
            "system-reboot-symbolic",
            NULL,
        };
        GtkWidget *button = gtk_button_new();
        gtk_widget_add_css_class(button, "bar-button");
        gtk_widget_add_css_class(button, "icon-button");
        gtk_widget_set_focusable(button, FALSE);
        gtk_widget_set_tooltip_text(button, "Energia");
        gtk_button_set_child(GTK_BUTTON(button), build_shell_icon(icons));
        g_signal_connect(button, "clicked", G_CALLBACK(on_power_clicked), state);
        gtk_box_append(GTK_BOX(right), button);
    }

    apply_css();

    if (gtk_layer_is_supported()) {
        gtk_layer_init_for_window(GTK_WINDOW(window));
        if (monitor != NULL) gtk_layer_set_monitor(GTK_WINDOW(window), monitor);
        gtk_layer_set_namespace(GTK_WINDOW(window), "axia-shell-v2");
        gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_TOP);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, 0);
        gtk_layer_set_keyboard_mode(GTK_WINDOW(window), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
        gtk_layer_auto_exclusive_zone_enable(GTK_WINDOW(window));
        gtk_layer_set_respect_close(GTK_WINDOW(window), TRUE);
    }

    if (monitor != NULL) g_object_unref(monitor);

    g_weak_ref_init(&state->clock_ref, G_OBJECT(clock));
    g_weak_ref_init(&state->audio_label_ref, G_OBJECT(audio_label));
    g_weak_ref_init(&state->audio_icon_ref, G_OBJECT(audio_icon));
    g_object_set_data_full(G_OBJECT(window), "axia-shell-state", state, shell_state_free);

    initialize_protocols(state);
    update_clock(state);
    update_audio_label(state);
    update_bluetooth_button(state);
    update_network_button(state);
    update_battery_button(state);
    g_timeout_add_seconds(1, update_clock, state);
    g_timeout_add_seconds(2, update_audio_label, state);
    g_timeout_add_seconds(5, update_bluetooth_button, state);
    g_timeout_add_seconds(5, update_network_button, state);
    g_timeout_add_seconds(15, update_battery_button, state);

    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.axia.shellv2", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
