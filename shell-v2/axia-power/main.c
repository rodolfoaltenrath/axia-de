#include <gtk/gtk.h>
#include <gtk4-layer-shell/gtk4-layer-shell.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

typedef struct {
    GtkApplication *app;
    GtkWidget *window;
    gboolean start_hidden;
} PowerState;

static void apply_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider, "shell-v2/axia-power/style.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
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
    }

    return NULL;
}

static GtkWidget *build_icon_sized(const char * const *icon_names, int pixel_size) {
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
        gtk_widget_add_css_class(icon, "bar-icon");
        g_free(local_path);
        return icon;
    }

    for (guint i = 0; icon_names[i] != NULL; i++) {
        GtkWidget *image = gtk_image_new_from_icon_name(icon_names[i]);
        gtk_widget_add_css_class(image, "bar-icon");
        gtk_image_set_pixel_size(GTK_IMAGE(image), pixel_size);
        if (gtk_image_get_storage_type(GTK_IMAGE(image)) != GTK_IMAGE_EMPTY) return image;
        g_object_unref(image);
    }

    GtkWidget *fallback = gtk_image_new_from_icon_name("applications-system-symbolic");
    gtk_widget_add_css_class(fallback, "bar-icon");
    gtk_image_set_pixel_size(GTK_IMAGE(fallback), pixel_size);
    return fallback;
}

static GtkWidget *build_icon(const char * const *icon_names) {
    return build_icon_sized(icon_names, 16);
}

static GtkWidget *build_power_action_icon(const char * const *icon_names) {
    GtkWidget *icon = build_icon_sized(icon_names, 72);
    gtk_widget_add_css_class(icon, "power-action-icon");
    gtk_widget_set_size_request(icon, 72, 72);
    return icon;
}

static gboolean spawn_command(const char *command) {
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
    if (!ok) {
        g_printerr("axia-power: failed to run command '%s': %s\n", command, error->message);
        g_clear_error(&error);
    }
    return ok;
}

static const char *settings_command(void) {
    const char *env = g_getenv("AXIA_V2_SETTINGS_CMD");
    if (env != NULL && *env != '\0') return env;
    return "./shell-v2/scripts/run-axia-settings.sh";
}

static void hide_menu(PowerState *state) {
    if (state == NULL || state->window == NULL) return;
    gtk_widget_set_visible(state->window, FALSE);
}

static void run_and_quit(GtkButton *button, gpointer user_data) {
    (void)button;
    const char *command = user_data;
    spawn_command(command);
}

static void open_settings(GtkButton *button, gpointer user_data) {
    (void)button;
    PowerState *state = user_data;
    spawn_command(settings_command());
    hide_menu(state);
}

static void lock_session(GtkButton *button, gpointer user_data) {
    (void)button;
    PowerState *state = user_data;
    spawn_command("loginctl lock-session");
    hide_menu(state);
}

static void logout_session(GtkButton *button, gpointer user_data) {
    (void)button;
    PowerState *state = user_data;
    spawn_command("loginctl terminate-session \"$XDG_SESSION_ID\"");
    hide_menu(state);
}

static void suspend_session(GtkButton *button, gpointer user_data) {
    (void)button;
    PowerState *state = user_data;
    spawn_command("systemctl suspend");
    hide_menu(state);
}

static void reboot_session(GtkButton *button, gpointer user_data) {
    (void)button;
    PowerState *state = user_data;
    spawn_command("systemctl reboot");
    hide_menu(state);
}

static void shutdown_session(GtkButton *button, gpointer user_data) {
    (void)button;
    PowerState *state = user_data;
    spawn_command("systemctl poweroff");
    hide_menu(state);
}

static void close_on_deactivate(GObject *object, GParamSpec *pspec, gpointer user_data) {
    (void)object;
    (void)pspec;
    PowerState *state = user_data;
    if (state == NULL || state->window == NULL) return;
    if (!gtk_window_is_active(GTK_WINDOW(state->window))) hide_menu(state);
}

static gboolean close_on_escape(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state_mods, gpointer user_data) {
    (void)controller;
    (void)keycode;
    (void)state_mods;
    PowerState *state = user_data;
    if (keyval == GDK_KEY_Escape) {
        hide_menu(state);
        return TRUE;
    }
    return FALSE;
}

static GtkWidget *build_session_row(const char *label_text, const char *shortcut_text, const char * const *icons, GCallback callback, gpointer user_data) {
    GtkWidget *button = gtk_button_new();
    gtk_widget_add_css_class(button, "shell-menu-row");
    gtk_widget_add_css_class(button, "session-row");
    gtk_widget_set_focusable(button, FALSE);
    g_signal_connect(button, "clicked", callback, user_data);

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_hexpand(left, TRUE);
    gtk_box_append(GTK_BOX(left), build_icon(icons));

    GtkWidget *label = gtk_label_new(label_text);
    gtk_widget_add_css_class(label, "shell-menu-row-text");
    gtk_widget_add_css_class(label, "session-row-text");
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_box_append(GTK_BOX(left), label);

    GtkWidget *shortcut = gtk_label_new(shortcut_text);
    gtk_widget_add_css_class(shortcut, "shell-menu-shortcut");
    gtk_widget_add_css_class(shortcut, "session-shortcut");
    gtk_label_set_xalign(GTK_LABEL(shortcut), 1.0f);

    gtk_box_append(GTK_BOX(row), left);
    gtk_box_append(GTK_BOX(row), shortcut);
    gtk_button_set_child(GTK_BUTTON(button), row);
    return button;
}

static void activate(GApplication *app, gpointer user_data) {
    (void)user_data;

    PowerState *state = g_object_get_data(G_OBJECT(app), "axia-power-state");
    if (state == NULL) {
        state = g_new0(PowerState, 1);
        state->app = GTK_APPLICATION(app);
        state->start_hidden = g_strcmp0(g_getenv("AXIA_POWER_PREWARM"), "1") == 0;
        g_application_hold(G_APPLICATION(app));
        g_object_set_data_full(G_OBJECT(app), "axia-power-state", state, g_free);
    }

    if (state->window == NULL) {
        GtkWidget *window = gtk_application_window_new(GTK_APPLICATION(app));
        state->window = window;

        gtk_window_set_title(GTK_WINDOW(window), "Axia Power Menu");
        gtk_window_set_default_size(GTK_WINDOW(window), 340, -1);
        gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
        gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
        gtk_window_set_hide_on_close(GTK_WINDOW(window), TRUE);

        GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_add_css_class(root, "power-menu-root");
        gtk_window_set_child(GTK_WINDOW(window), root);

        GtkWidget *frame = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_add_css_class(frame, "power-frame");
        gtk_widget_set_margin_start(frame, 12);
        gtk_widget_set_margin_end(frame, 12);
        gtk_widget_set_margin_top(frame, 12);
        gtk_widget_set_margin_bottom(frame, 12);
        gtk_box_append(GTK_BOX(root), frame);

        GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_widget_add_css_class(content, "shell-menu-content");
        gtk_widget_add_css_class(content, "power-popover-content");
        gtk_box_append(GTK_BOX(frame), content);

        GtkWidget *settings = gtk_button_new();
        gtk_widget_add_css_class(settings, "shell-menu-row");
        gtk_widget_add_css_class(settings, "session-row");
        gtk_widget_set_focusable(settings, FALSE);
        g_signal_connect(settings, "clicked", G_CALLBACK(open_settings), state);
        GtkWidget *settings_label = gtk_label_new("Configurações...");
        gtk_widget_add_css_class(settings_label, "shell-menu-row-text");
        gtk_widget_add_css_class(settings_label, "session-row-text");
        gtk_label_set_xalign(GTK_LABEL(settings_label), 0.0f);
        gtk_button_set_child(GTK_BUTTON(settings), settings_label);
        gtk_box_append(GTK_BOX(content), settings);

        GtkWidget *separator_top = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
        gtk_widget_add_css_class(separator_top, "shell-menu-separator");
        gtk_widget_add_css_class(separator_top, "power-separator");
        gtk_box_append(GTK_BOX(content), separator_top);

        gtk_box_append(GTK_BOX(content), build_session_row(
            "Bloquear Tela",
            "Super + Esc",
            (const char * const[]) {
                "system-lock-screen-symbolic",
                "changes-prevent-symbolic",
                NULL,
            },
            G_CALLBACK(lock_session),
            state));

        gtk_box_append(GTK_BOX(content), build_session_row(
            "Sair",
            "Super + Shift + Esc",
            (const char * const[]) {
                "system-log-out-symbolic",
                "application-exit-symbolic",
                NULL,
            },
            G_CALLBACK(logout_session),
            state));

        GtkWidget *separator_bottom = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
        gtk_widget_add_css_class(separator_bottom, "shell-menu-separator");
        gtk_widget_add_css_class(separator_bottom, "power-separator");
        gtk_box_append(GTK_BOX(content), separator_bottom);

        GtkWidget *power_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 22);
        gtk_widget_add_css_class(power_row, "shell-menu-actions");
        gtk_widget_add_css_class(power_row, "power-icon-row");
        gtk_widget_set_halign(power_row, GTK_ALIGN_CENTER);

        GtkWidget *suspend = gtk_button_new();
        gtk_widget_add_css_class(suspend, "shell-menu-action");
        gtk_widget_add_css_class(suspend, "power-icon-action");
        gtk_widget_set_focusable(suspend, FALSE);
        gtk_widget_set_tooltip_text(suspend, "Suspender");
        gtk_button_set_child(GTK_BUTTON(suspend), build_power_action_icon((const char * const[]) {
            "system-suspend-symbolic",
            "media-playback-pause-symbolic",
            NULL,
        }));
        g_signal_connect(suspend, "clicked", G_CALLBACK(suspend_session), state);

        GtkWidget *reboot = gtk_button_new();
        gtk_widget_add_css_class(reboot, "shell-menu-action");
        gtk_widget_add_css_class(reboot, "power-icon-action");
        gtk_widget_set_focusable(reboot, FALSE);
        gtk_widget_set_tooltip_text(reboot, "Reiniciar");
        gtk_button_set_child(GTK_BUTTON(reboot), build_power_action_icon((const char * const[]) {
            "system-reboot-symbolic",
            "view-refresh-symbolic",
            NULL,
        }));
        g_signal_connect(reboot, "clicked", G_CALLBACK(reboot_session), state);

        GtkWidget *poweroff = gtk_button_new();
        gtk_widget_add_css_class(poweroff, "shell-menu-action");
        gtk_widget_add_css_class(poweroff, "power-icon-action");
        gtk_widget_add_css_class(poweroff, "power-danger");
        gtk_widget_set_focusable(poweroff, FALSE);
        gtk_widget_set_tooltip_text(poweroff, "Desligar");
        gtk_button_set_child(GTK_BUTTON(poweroff), build_power_action_icon((const char * const[]) {
            "system-shutdown-symbolic",
            "system-log-out-symbolic",
            NULL,
        }));
        g_signal_connect(poweroff, "clicked", G_CALLBACK(shutdown_session), state);

        gtk_box_append(GTK_BOX(power_row), suspend);
        gtk_box_append(GTK_BOX(power_row), reboot);
        gtk_box_append(GTK_BOX(power_row), poweroff);
        gtk_box_append(GTK_BOX(content), power_row);

        apply_css();

        if (gtk_layer_is_supported()) {
            gtk_layer_init_for_window(GTK_WINDOW(window));
            gtk_layer_set_namespace(GTK_WINDOW(window), "axia-power-v2");
            gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_OVERLAY);
            gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
            gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
            gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, 34);
            gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, 10);
            gtk_layer_set_keyboard_mode(GTK_WINDOW(window), GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
            gtk_layer_set_respect_close(GTK_WINDOW(window), TRUE);
        }

        GtkEventController *keys = gtk_event_controller_key_new();
        g_signal_connect(keys, "key-pressed", G_CALLBACK(close_on_escape), state);
        gtk_widget_add_controller(window, keys);
        g_signal_connect(window, "notify::is-active", G_CALLBACK(close_on_deactivate), state);
    }

    if (!state->start_hidden) {
        gtk_window_present(GTK_WINDOW(state->window));
    } else {
        state->start_hidden = FALSE;
    }
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.axia.power", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    const int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
