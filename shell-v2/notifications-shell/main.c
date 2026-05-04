#include <errno.h>
#include <gtk/gtk.h>
#include <gtk4-layer-shell/gtk4-layer-shell.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct {
    guint id;
    char level[16];
    char message[192];
} NotificationItem;

typedef struct {
    GtkWidget *window;
    GtkWidget *header_label;
    GtkWidget *dnd_button;
    GtkWidget *list_box;
    char *socket_path;
    gboolean dnd_enabled;
    guint count;
    NotificationItem items[16];
} NotificationShellState;

static void notification_shell_state_free(gpointer data) {
    NotificationShellState *state = data;
    if (state == NULL) return;
    g_free(state->socket_path);
    g_free(state);
}

static void apply_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider, "shell-v2/notifications-shell/style.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static gboolean request_ipc(NotificationShellState *state, const char *payload, char **response_out) {
    *response_out = NULL;
    if (state->socket_path == NULL || state->socket_path[0] == '\0') return FALSE;

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return FALSE;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    g_strlcpy(addr.sun_path, state->socket_path, sizeof(addr.sun_path));

    if (connect(fd, (const struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return FALSE;
    }

    if (write(fd, payload, strlen(payload)) < 0) {
        close(fd);
        return FALSE;
    }

    GString *buffer = g_string_new(NULL);
    char chunk[512];
    for (;;) {
        ssize_t len = read(fd, chunk, sizeof(chunk));
        if (len <= 0) break;
        g_string_append_len(buffer, chunk, (gssize)len);
        if (len < (ssize_t)sizeof(chunk)) break;
    }
    close(fd);

    *response_out = g_string_free(buffer, FALSE);
    return TRUE;
}

static const char *title_for_level(const char *level) {
    if (g_ascii_strcasecmp(level, "success") == 0) return "Sucesso";
    if (g_ascii_strcasecmp(level, "warning") == 0) return "Aviso";
    if (g_ascii_strcasecmp(level, "error") == 0) return "Erro";
    return "Info";
}

static void clear_box(GtkWidget *box) {
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child != NULL) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(box), child);
        child = next;
    }
}

static void rebuild_notifications_ui(NotificationShellState *state) {
    clear_box(state->list_box);

    char *header = g_strdup_printf("Notificacoes %u", state->count);
    gtk_label_set_text(GTK_LABEL(state->header_label), header);
    g_free(header);

    gtk_button_set_label(GTK_BUTTON(state->dnd_button), state->dnd_enabled ? "DND: ligado" : "DND: desligado");

    if (state->count == 0) {
        GtkWidget *empty = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
        gtk_widget_add_css_class(empty, "notification-card");
        gtk_widget_add_css_class(empty, "notification-empty");

        GtkWidget *title = gtk_label_new("Sem notificacoes");
        gtk_widget_add_css_class(title, "card-title");
        gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
        gtk_box_append(GTK_BOX(empty), title);

        GtkWidget *body = gtk_label_new("Quando algo chegar na sessao, aparece aqui.");
        gtk_widget_add_css_class(body, "card-body");
        gtk_label_set_xalign(GTK_LABEL(body), 0.0f);
        gtk_label_set_wrap(GTK_LABEL(body), TRUE);
        gtk_box_append(GTK_BOX(empty), body);

        gtk_box_append(GTK_BOX(state->list_box), empty);
        return;
    }

    for (guint i = 0; i < state->count; i++) {
        GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_widget_add_css_class(card, "notification-card");

        if (g_ascii_strcasecmp(state->items[i].level, "success") == 0) {
            gtk_widget_add_css_class(card, "level-success");
        } else if (g_ascii_strcasecmp(state->items[i].level, "warning") == 0) {
            gtk_widget_add_css_class(card, "level-warning");
        } else if (g_ascii_strcasecmp(state->items[i].level, "error") == 0) {
            gtk_widget_add_css_class(card, "level-error");
        } else {
            gtk_widget_add_css_class(card, "level-info");
        }

        GtkWidget *title = gtk_label_new(title_for_level(state->items[i].level));
        gtk_widget_add_css_class(title, "card-title");
        gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
        gtk_box_append(GTK_BOX(card), title);

        GtkWidget *body = gtk_label_new(state->items[i].message);
        gtk_widget_add_css_class(body, "card-body");
        gtk_label_set_xalign(GTK_LABEL(body), 0.0f);
        gtk_label_set_wrap(GTK_LABEL(body), TRUE);
        gtk_box_append(GTK_BOX(card), body);

        gtk_box_append(GTK_BOX(state->list_box), card);
    }
}

static gboolean refresh_notifications(gpointer data) {
    NotificationShellState *state = data;
    char *response = NULL;
    if (!request_ipc(state, "notification get\n", &response)) {
        gtk_label_set_text(GTK_LABEL(state->header_label), "Notificacoes indisponiveis");
        return G_SOURCE_CONTINUE;
    }

    state->count = 0;
    state->dnd_enabled = FALSE;

    gchar **lines = g_strsplit(response, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        char *line = g_strstrip(lines[i]);
        if (*line == '\0') continue;

        if (g_str_has_prefix(line, "ok notifications ")) {
            guint count = 0;
            guint dnd = 0;
            if (sscanf(line, "ok notifications %u %u", &count, &dnd) == 2) {
                state->count = MIN(count, G_N_ELEMENTS(state->items));
                state->dnd_enabled = dnd != 0;
            }
            continue;
        }

        if (!g_str_has_prefix(line, "notification ")) continue;
        if (state->count == 0) continue;

        guint id = 0;
        long long created_ms = 0;
        char level[16] = {0};
        char message[192] = {0};
        if (sscanf(line, "notification %u %lld %15s %191[^\n]", &id, &created_ms, level, message) >= 4) {
            guint index = 0;
            while (index < G_N_ELEMENTS(state->items) && state->items[index].id != 0) index++;
            if (index < state->count && index < G_N_ELEMENTS(state->items)) {
                state->items[index].id = id;
                g_strlcpy(state->items[index].level, level, sizeof(state->items[index].level));
                g_strlcpy(state->items[index].message, message, sizeof(state->items[index].message));
            }
        }
    }

    guint compact = 0;
    for (guint i = 0; i < G_N_ELEMENTS(state->items); i++) {
        if (state->items[i].id == 0) continue;
        if (compact != i) state->items[compact] = state->items[i];
        compact++;
    }
    for (guint i = compact; i < G_N_ELEMENTS(state->items); i++) {
        memset(&state->items[i], 0, sizeof(state->items[i]));
    }
    state->count = compact;

    rebuild_notifications_ui(state);

    g_strfreev(lines);
    g_free(response);
    return G_SOURCE_CONTINUE;
}

static void toggle_dnd(GtkButton *button, gpointer user_data) {
    (void)button;
    NotificationShellState *state = user_data;
    char command[64];
    g_snprintf(command, sizeof(command), "notification dnd %u\n", state->dnd_enabled ? 0 : 1);

    char *response = NULL;
    if (request_ipc(state, command, &response)) {
        g_free(response);
        refresh_notifications(state);
    }
}

static void activate(GApplication *app, gpointer user_data) {
    (void)user_data;

    GtkWidget *window = gtk_application_window_new(GTK_APPLICATION(app));
    gtk_window_set_title(GTK_WINDOW(window), "Axia Notifications");
    gtk_window_set_default_size(GTK_WINDOW(window), 380, 420);
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(root, "notifications-root");
    gtk_window_set_child(GTK_WINDOW(window), root);

    GtkWidget *frame = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_add_css_class(frame, "notifications-frame");
    gtk_widget_set_margin_start(frame, 12);
    gtk_widget_set_margin_end(frame, 12);
    gtk_widget_set_margin_top(frame, 12);
    gtk_widget_set_margin_bottom(frame, 12);
    gtk_box_append(GTK_BOX(root), frame);

    GtkWidget *header_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(frame), header_row);

    GtkWidget *header = gtk_label_new("Notificacoes");
    gtk_widget_add_css_class(header, "notifications-title");
    gtk_label_set_xalign(GTK_LABEL(header), 0.0f);
    gtk_widget_set_hexpand(header, TRUE);
    gtk_box_append(GTK_BOX(header_row), header);

    GtkWidget *dnd = gtk_button_new_with_label("DND: desligado");
    gtk_widget_add_css_class(dnd, "dnd-button");
    gtk_box_append(GTK_BOX(header_row), dnd);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_box_append(GTK_BOX(frame), scroll);

    GtkWidget *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(list, "notifications-list");
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);

    apply_css();

    if (gtk_layer_is_supported()) {
        gtk_layer_init_for_window(GTK_WINDOW(window));
        gtk_layer_set_namespace(GTK_WINDOW(window), "axia-notifications-v2");
        gtk_layer_set_layer(GTK_WINDOW(window), GTK_LAYER_SHELL_LAYER_OVERLAY);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
        gtk_layer_set_anchor(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_TOP, 52);
        gtk_layer_set_margin(GTK_WINDOW(window), GTK_LAYER_SHELL_EDGE_RIGHT, 16);
        gtk_layer_set_keyboard_mode(GTK_WINDOW(window), GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
        gtk_layer_set_exclusive_zone(GTK_WINDOW(window), -1);
        gtk_layer_set_respect_close(GTK_WINDOW(window), TRUE);
    }

    NotificationShellState *state = g_new0(NotificationShellState, 1);
    state->window = window;
    state->header_label = header;
    state->dnd_button = dnd;
    state->list_box = list;
    state->socket_path = g_strdup(g_getenv("AXIA_IPC_SOCKET"));
    g_signal_connect(dnd, "clicked", G_CALLBACK(toggle_dnd), state);
    g_object_set_data_full(G_OBJECT(window), "axia-notifications-state", state, notification_shell_state_free);

    refresh_notifications(state);
    g_timeout_add_seconds(2, refresh_notifications, state);
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.axia.shellv2.notifications", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
