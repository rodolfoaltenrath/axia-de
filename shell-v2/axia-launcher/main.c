#include <gtk/gtk.h>
#include <gio/gdesktopappinfo.h>

typedef struct {
    char *id;
    char *name;
    char *icon;
} AppItem;

typedef struct {
    GPtrArray *favorites;
    GPtrArray *recents;
} LauncherState;

typedef struct {
    GtkWidget *window;
    GtkWidget *search;
    GtkWidget *favorites_box;
    GtkWidget *recents_box;
    GtkWidget *apps_box;
    GtkWidget *stack;
    GPtrArray *apps;
    LauncherState state;
} LauncherUi;

static void launcher_state_free(LauncherState *state);
static void rebuild_ui(LauncherUi *ui, const char *query);

static void app_item_free(gpointer data) {
    AppItem *item = data;
    g_free(item->id);
    g_free(item->name);
    g_free(item->icon);
    g_free(item);
}

static void launcher_ui_free(gpointer data) {
    LauncherUi *ui = data;
    if (!ui) return;
    if (ui->apps) g_ptr_array_free(ui->apps, TRUE);
    launcher_state_free(&ui->state);
    g_free(ui);
}

static gchar *config_home(void) {
    const char *xdg = g_getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg) return g_strdup(xdg);
    const char *home = g_getenv("HOME");
    if (home && *home) return g_build_filename(home, ".config", NULL);
    return g_strdup(".config");
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

static LauncherState launcher_state_load(void) {
    LauncherState state = {
        .favorites = g_ptr_array_new_with_free_func(g_free),
        .recents = g_ptr_array_new_with_free_func(g_free),
    };
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

static gboolean is_favorite(LauncherState *state, const char *id) {
    for (guint i = 0; i < state->favorites->len; i++) {
        const char *item = g_ptr_array_index(state->favorites, i);
        if (g_strcmp0(item, id) == 0) return TRUE;
    }
    return FALSE;
}

static void toggle_favorite(LauncherState *state, const char *id) {
    if (!is_valid_launcher_id(id)) return;
    for (guint i = 0; i < state->favorites->len; i++) {
        const char *item = g_ptr_array_index(state->favorites, i);
        if (g_strcmp0(item, id) == 0) {
            g_ptr_array_remove_index(state->favorites, i);
            launcher_state_save(state);
            return;
        }
    }
    if (!string_array_contains(state->favorites, id)) {
        g_ptr_array_add(state->favorites, g_strdup(id));
    }
    launcher_state_save(state);
}

static void move_favorite(LauncherState *state, const char *id, int delta) {
    int from = -1;
    for (guint i = 0; i < state->favorites->len; i++) {
        const char *item = g_ptr_array_index(state->favorites, i);
        if (g_strcmp0(item, id) == 0) {
            from = (int)i;
            break;
        }
    }
    if (from < 0) return;
    int to = from + delta;
    if (to < 0) to = 0;
    if (to >= (int)state->favorites->len) to = (int)state->favorites->len - 1;
    if (to == from) return;
    gpointer moved = g_ptr_array_steal_index(state->favorites, from);
    g_ptr_array_insert(state->favorites, to, moved);
    launcher_state_save(state);
}

static void record_recent(LauncherState *state, const char *id) {
    if (!is_valid_launcher_id(id)) return;
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

static gchar *resolve_icon_for_app(const char *app_id) {
    if (!app_id || !*app_id) return g_strdup("application-x-executable-symbolic");
    GDesktopAppInfo *info = g_desktop_app_info_new(app_id);
    if (info) {
        GIcon *icon = g_app_info_get_icon(G_APP_INFO(info));
        if (G_IS_THEMED_ICON(icon)) {
            const char *const *names = g_themed_icon_get_names(G_THEMED_ICON(icon));
            if (names && names[0]) {
                gchar *result = g_strdup(names[0]);
                g_object_unref(info);
                return result;
            }
        }
        g_object_unref(info);
    }
    return g_strdup("application-x-executable-symbolic");
}

static gboolean launch_app_id(const char *app_id) {
    if (!app_id || !*app_id) return FALSE;
    GDesktopAppInfo *info = g_desktop_app_info_new(app_id);
    if (!info) return FALSE;
    GError *error = NULL;
    gboolean ok = g_app_info_launch(G_APP_INFO(info), NULL, NULL, &error);
    if (!ok && error) g_clear_error(&error);
    g_object_unref(info);
    return ok;
}

static GtkWidget *build_app_button(LauncherUi *ui, AppItem *item) {
    GtkWidget *button = gtk_button_new();
    gtk_widget_add_css_class(button, "app-tile");
    gtk_widget_set_focusable(button, FALSE);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_button_set_child(GTK_BUTTON(button), box);

    gchar *icon_name = resolve_icon_for_app(item->id);
    GtkWidget *icon = gtk_image_new_from_icon_name(icon_name);
    gtk_image_set_pixel_size(GTK_IMAGE(icon), 44);
    gtk_box_append(GTK_BOX(box), icon);
    g_free(icon_name);

    GtkWidget *label = gtk_label_new(item->name);
    gtk_widget_add_css_class(label, "app-tile-label");
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 14);
    gtk_box_append(GTK_BOX(box), label);

    g_object_set_data(G_OBJECT(button), "app-id", item->id);
    g_object_set_data(G_OBJECT(button), "launcher-ui", ui);

    return button;
}

static void on_launch_clicked(GtkButton *button, gpointer user_data) {
    (void)user_data;
    LauncherUi *ui = g_object_get_data(G_OBJECT(button), "launcher-ui");
    const char *app_id = g_object_get_data(G_OBJECT(button), "app-id");
    if (!ui || !app_id) return;
    if (launch_app_id(app_id)) {
        record_recent(&ui->state, app_id);
        gtk_window_close(GTK_WINDOW(ui->window));
    }
}

static void on_menu_action(GtkButton *button, gpointer user_data) {
    LauncherUi *ui = user_data;
    const char *app_id = g_object_get_data(G_OBJECT(button), "app-id");
    const char *action = g_object_get_data(G_OBJECT(button), "action");
    if (!ui || !app_id || !action) return;

    if (g_strcmp0(action, "favorite") == 0) {
        toggle_favorite(&ui->state, app_id);
    } else if (g_strcmp0(action, "left") == 0) {
        move_favorite(&ui->state, app_id, -1);
    } else if (g_strcmp0(action, "right") == 0) {
        move_favorite(&ui->state, app_id, +1);
    }

    const char *query = gtk_editable_get_text(GTK_EDITABLE(ui->search));
    rebuild_ui(ui, query);
}

static void show_context_menu(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data) {
    (void)n_press; (void)x; (void)y;
    GtkWidget *button = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    LauncherUi *ui = g_object_get_data(G_OBJECT(button), "launcher-ui");
    const char *app_id = g_object_get_data(G_OBJECT(button), "app-id");
    if (!ui || !app_id) return;

    GtkWidget *popover = gtk_popover_new();
    gtk_widget_add_css_class(popover, "launcher-menu");
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_popover_set_child(GTK_POPOVER(popover), box);

    const char *pin_label = is_favorite(&ui->state, app_id) ? "Desafixar" : "Fixar";
    GtkWidget *pin = gtk_button_new_with_label(pin_label);
    gtk_widget_add_css_class(pin, "launcher-menu-button");
    g_object_set_data(G_OBJECT(pin), "app-id", (gpointer)app_id);
    g_object_set_data(G_OBJECT(pin), "action", "favorite");
    g_signal_connect(pin, "clicked", G_CALLBACK(on_menu_action), ui);
    gtk_box_append(GTK_BOX(box), pin);

    GtkWidget *left = gtk_button_new_with_label("Mover para esquerda");
    gtk_widget_add_css_class(left, "launcher-menu-button");
    g_object_set_data(G_OBJECT(left), "app-id", (gpointer)app_id);
    g_object_set_data(G_OBJECT(left), "action", "left");
    g_signal_connect(left, "clicked", G_CALLBACK(on_menu_action), ui);
    gtk_box_append(GTK_BOX(box), left);

    GtkWidget *right = gtk_button_new_with_label("Mover para direita");
    gtk_widget_add_css_class(right, "launcher-menu-button");
    g_object_set_data(G_OBJECT(right), "app-id", (gpointer)app_id);
    g_object_set_data(G_OBJECT(right), "action", "right");
    g_signal_connect(right, "clicked", G_CALLBACK(on_menu_action), ui);
    gtk_box_append(GTK_BOX(box), right);

    gtk_popover_set_has_arrow(GTK_POPOVER(popover), TRUE);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), &(GdkRectangle){ .x = (int)x, .y = (int)y, .width = 1, .height = 1 });
    gtk_widget_set_parent(GTK_WIDGET(popover), button);
    gtk_popover_popup(GTK_POPOVER(popover));
}

static GPtrArray *load_desktop_apps(void) {
    GList *all = g_app_info_get_all();
    GPtrArray *items = g_ptr_array_new_with_free_func(app_item_free);
    for (GList *l = all; l != NULL; l = l->next) {
        GAppInfo *info = l->data;
        if (!G_IS_DESKTOP_APP_INFO(info)) continue;
        if (!g_app_info_should_show(info)) continue;
        const char *id = g_app_info_get_id(info);
        const char *name = g_app_info_get_display_name(info);
        if (!id || !name) continue;
        AppItem *item = g_new0(AppItem, 1);
        item->id = g_strdup(id);
        item->name = g_strdup(name);
        item->icon = resolve_icon_for_app(id);
        g_ptr_array_add(items, item);
    }
    g_list_free_full(all, g_object_unref);
    return items;
}

static void clear_flow(GtkWidget *box) {
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(box), child);
        child = next;
    }
}

static gboolean matches_search(const char *text, const char *query) {
    if (!query || !*query) return TRUE;
    gchar *q = g_ascii_strdown(query, -1);
    gchar *t = g_ascii_strdown(text ? text : "", -1);
    gboolean ok = strstr(t, q) != NULL;
    g_free(q);
    g_free(t);
    return ok;
}

static void populate_section(GtkWidget *container, LauncherUi *ui, GPtrArray *list) {
    clear_flow(container);
    for (guint i = 0; i < list->len; i++) {
        AppItem *item = g_ptr_array_index(list, i);
        GtkWidget *button = build_app_button(ui, item);
        gtk_box_append(GTK_BOX(container), button);
        g_signal_connect(button, "clicked", G_CALLBACK(on_launch_clicked), NULL);
        GtkGesture *right = gtk_gesture_click_new();
        gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(right), GDK_BUTTON_SECONDARY);
        g_object_set_data(G_OBJECT(right), "launcher-ui", ui);
        g_object_set_data(G_OBJECT(right), "app-id", item->id);
        g_signal_connect(right, "pressed", G_CALLBACK(show_context_menu), NULL);
        gtk_widget_add_controller(button, GTK_EVENT_CONTROLLER(right));
    }
}

static GPtrArray *filter_apps(LauncherUi *ui, const char *query) {
    GPtrArray *filtered = g_ptr_array_new_with_free_func(NULL);
    for (guint i = 0; i < ui->apps->len; i++) {
        AppItem *item = g_ptr_array_index(ui->apps, i);
        if (matches_search(item->name, query) || matches_search(item->id, query)) {
            g_ptr_array_add(filtered, item);
        }
    }
    return filtered;
}

static void rebuild_ui(LauncherUi *ui, const char *query) {
    GPtrArray *fav_items = g_ptr_array_new_with_free_func(NULL);
    for (guint i = 0; i < ui->state.favorites->len; i++) {
        const char *id = g_ptr_array_index(ui->state.favorites, i);
        for (guint j = 0; j < ui->apps->len; j++) {
            AppItem *item = g_ptr_array_index(ui->apps, j);
            if (g_strcmp0(item->id, id) == 0) {
                g_ptr_array_add(fav_items, item);
                break;
            }
        }
    }

    GPtrArray *recent_items = g_ptr_array_new_with_free_func(NULL);
    for (guint i = 0; i < ui->state.recents->len; i++) {
        const char *id = g_ptr_array_index(ui->state.recents, i);
        for (guint j = 0; j < ui->apps->len; j++) {
            AppItem *item = g_ptr_array_index(ui->apps, j);
            if (g_strcmp0(item->id, id) == 0) {
                g_ptr_array_add(recent_items, item);
                break;
            }
        }
    }

    GPtrArray *filtered = filter_apps(ui, query);
    populate_section(ui->favorites_box, ui, fav_items);
    populate_section(ui->recents_box, ui, recent_items);
    populate_section(ui->apps_box, ui, filtered);

    g_ptr_array_free(fav_items, TRUE);
    g_ptr_array_free(recent_items, TRUE);
    g_ptr_array_free(filtered, TRUE);
}

static void on_search_changed(GtkEditable *editable, gpointer user_data) {
    LauncherUi *ui = user_data;
    const char *text = gtk_editable_get_text(editable);
    rebuild_ui(ui, text);
}

static void apply_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider, "shell-v2/axia-launcher/style.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static void on_activate(GtkApplication *app, gpointer user_data) {
    (void)user_data;
    apply_css();

    LauncherUi *ui = g_new0(LauncherUi, 1);
    ui->apps = load_desktop_apps();
    ui->state = launcher_state_load();
    launcher_state_save(&ui->state);

    ui->window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(ui->window), "Aplicativos");
    gtk_window_set_default_size(GTK_WINDOW(ui->window), 760, 432);
    gtk_window_set_resizable(GTK_WINDOW(ui->window), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(ui->window), FALSE);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_add_css_class(root, "launcher-root");
    gtk_window_set_child(GTK_WINDOW(ui->window), root);

    ui->search = gtk_search_entry_new();
    gtk_widget_add_css_class(ui->search, "launcher-search");
    gtk_box_append(GTK_BOX(root), ui->search);
    g_signal_connect(ui->search, "search-changed", G_CALLBACK(on_search_changed), ui);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_box_append(GTK_BOX(root), scroll);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(content, 16);
    gtk_widget_set_margin_end(content, 16);
    gtk_widget_set_margin_bottom(content, 16);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), content);

    GtkWidget *fav_label = gtk_label_new("Favoritos");
    gtk_widget_add_css_class(fav_label, "section-title");
    gtk_label_set_xalign(GTK_LABEL(fav_label), 0.0f);
    gtk_box_append(GTK_BOX(content), fav_label);

    ui->favorites_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(ui->favorites_box, "section-row");
    gtk_box_set_spacing(GTK_BOX(ui->favorites_box), 12);
    gtk_box_append(GTK_BOX(content), ui->favorites_box);

    GtkWidget *recent_label = gtk_label_new("Recentes");
    gtk_widget_add_css_class(recent_label, "section-title");
    gtk_label_set_xalign(GTK_LABEL(recent_label), 0.0f);
    gtk_box_append(GTK_BOX(content), recent_label);

    ui->recents_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(ui->recents_box, "section-row");
    gtk_box_set_spacing(GTK_BOX(ui->recents_box), 12);
    gtk_box_append(GTK_BOX(content), ui->recents_box);

    GtkWidget *all_label = gtk_label_new("Todos");
    gtk_widget_add_css_class(all_label, "section-title");
    gtk_label_set_xalign(GTK_LABEL(all_label), 0.0f);
    gtk_box_append(GTK_BOX(content), all_label);

    ui->apps_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(ui->apps_box, "section-row");
    gtk_box_set_spacing(GTK_BOX(ui->apps_box), 12);
    gtk_box_append(GTK_BOX(content), ui->apps_box);

    rebuild_ui(ui, "");

    g_object_set_data_full(G_OBJECT(ui->window), "launcher-ui", ui, launcher_ui_free);
    gtk_window_present(GTK_WINDOW(ui->window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.axia.launcher", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
