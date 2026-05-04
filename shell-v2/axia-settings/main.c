#include <gtk/gtk.h>

static void apply_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider, "shell-v2/axia-settings/style.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(),
        GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static GtkWidget *section_card(const char *title, const char *subtitle) {
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(card, "settings-card");

    GtkWidget *heading = gtk_label_new(title);
    gtk_widget_add_css_class(heading, "settings-card-title");
    gtk_label_set_xalign(GTK_LABEL(heading), 0.0f);

    GtkWidget *body = gtk_label_new(subtitle);
    gtk_widget_add_css_class(body, "settings-card-body");
    gtk_label_set_wrap(GTK_LABEL(body), TRUE);
    gtk_label_set_xalign(GTK_LABEL(body), 0.0f);

    gtk_box_append(GTK_BOX(card), heading);
    gtk_box_append(GTK_BOX(card), body);
    return card;
}

static GtkWidget *settings_window(GtkApplication *app) {
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Axia Settings");
    gtk_window_set_default_size(GTK_WINDOW(window), 960, 640);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(root, "settings-root");
    gtk_window_set_child(GTK_WINDOW(window), root);

    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(header, "settings-header");
    gtk_widget_set_margin_top(header, 24);
    gtk_widget_set_margin_start(header, 24);
    gtk_widget_set_margin_end(header, 24);
    gtk_box_append(GTK_BOX(root), header);

    GtkWidget *title = gtk_label_new("Configuracoes");
    gtk_widget_add_css_class(title, "settings-title");
    gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
    gtk_box_append(GTK_BOX(header), title);

    GtkWidget *subtitle = gtk_label_new("Escolha uma categoria para ajustar o ambiente do Axia.");
    gtk_widget_add_css_class(subtitle, "settings-subtitle");
    gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0f);
    gtk_box_append(GTK_BOX(header), subtitle);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_widget_set_margin_top(scroll, 12);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_box_append(GTK_BOX(root), scroll);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(content, 24);
    gtk_widget_set_margin_end(content, 24);
    gtk_widget_set_margin_bottom(content, 24);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), content);

    gtk_box_append(GTK_BOX(content), section_card("Telas", "Resolucao, escala, arranjo e modo de cada monitor."));
    gtk_box_append(GTK_BOX(content), section_card("Dock", "Tamanho, espacamento, itens fixos e animacoes."));
    gtk_box_append(GTK_BOX(content), section_card("Barra superior", "Relogio, icones de status e atalhos rapidos."));
    gtk_box_append(GTK_BOX(content), section_card("Sessao", "Bloqueio, energia e comportamento ao iniciar."));

    return window;
}

static void on_activate(GtkApplication *app, gpointer user_data) {
    (void)user_data;
    apply_css();
    GtkWidget *window = settings_window(app);
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.axia.settings", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
