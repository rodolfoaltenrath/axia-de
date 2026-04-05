const std = @import("std");
const c = @import("client_wl").c;
const chrome = @import("client_chrome");
const settings_model = @import("settings_model");
const settings_files = @import("settings_files");

pub const window_width: u32 = 1040;
pub const window_height: u32 = 760;

const titlebar_height = chrome.titlebar_height;
const sidebar_width = 228.0;
const content_padding = 24.0;
const preset_card_width = 204.0;
const preset_card_height = 152.0;
const preset_gap = 16.0;

pub const Rect = chrome.Rect;

pub const Hit = union(enum) {
    none,
    titlebar,
    minimize,
    maximize,
    close,
    nav: settings_model.Page,
    wallpaper_preset: usize,
    browser_home,
    browser_pictures,
    browser_downloads,
    browser_up,
    browser_prev,
    browser_next,
    browser_entry: usize,
};

pub const State = struct {
    page: settings_model.Page,
    hovered: Hit = .none,
    current_wallpaper_path: ?[]const u8 = null,
    browser: settings_files.Snapshot = .{},
};

const NavItem = struct {
    page: settings_model.Page,
    label: []const u8,
    icon: []const u8,
};

const nav_items = [_]NavItem{
    .{ .page = .wallpapers, .label = "Papel de Parede", .icon = "P" },
    .{ .page = .appearance, .label = "Aparência", .icon = "A" },
    .{ .page = .panel, .label = "Painel Superior", .icon = "T" },
    .{ .page = .displays, .label = "Monitores", .icon = "M" },
    .{ .page = .workspaces, .label = "Áreas de Trabalho", .icon = "W" },
    .{ .page = .network, .label = "Rede", .icon = "R" },
    .{ .page = .bluetooth, .label = "Bluetooth", .icon = "B" },
    .{ .page = .printers, .label = "Impressoras", .icon = "I" },
    .{ .page = .about, .label = "Sobre", .icon = "S" },
};

pub fn hitTest(width: u32, height: u32, x: f64, y: f64, state: State) Hit {
    if (closeRect(width).contains(x, y)) return .close;
    if (maximizeRect(width).contains(x, y)) return .maximize;
    if (minimizeRect(width).contains(x, y)) return .minimize;
    if (titlebarDragRect(width, height).contains(x, y)) return .titlebar;

    const sidebar = sidebarRect(width, height);
    for (nav_items, 0..) |item, index| {
        if (navItemRect(sidebar, index).contains(x, y)) return .{ .nav = item.page };
    }

    if (state.page == .wallpapers) {
        for (settings_model.wallpaper_presets, 0..) |_, index| {
            if (wallpaperCardRect(width, height, index).contains(x, y)) return .{ .wallpaper_preset = index };
        }
        if (browserHomeRect(width, height).contains(x, y)) return .browser_home;
        if (browserPicturesRect(width, height).contains(x, y)) return .browser_pictures;
        if (browserDownloadsRect(width, height).contains(x, y)) return .browser_downloads;
        if (browserUpRect(width, height).contains(x, y)) return .browser_up;
        if (browserPrevRect(width, height).contains(x, y)) return .browser_prev;
        if (browserNextRect(width, height).contains(x, y)) return .browser_next;
        for (0..state.browser.count) |index| {
            if (browserEntryRect(width, height, index).contains(x, y)) return .{ .browser_entry = index };
        }
    }

    return .none;
}

pub fn draw(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    chrome.drawWindowShell(cr, width, height, .{
        .title = "Configurações",
        .accent_glyph = "S",
        .accent_color = .{ 0.34, 0.86, 0.98 },
    }, hoveredControl(state.hovered));
    drawSidebar(cr, width, height, state.page, state.hovered);
    drawContent(cr, width, height, state);
}

fn drawSidebar(cr: *c.cairo_t, width: u32, height: u32, current_page: settings_model.Page, hovered: Hit) void {
    const sidebar = sidebarRect(width, height);
    drawRoundedRect(cr, sidebar, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
    c.cairo_fill(cr);

    drawLabel(cr, sidebar.x + 18, sidebar.y + 28, 13, "Configurações", 0.96, 0.97, 0.98, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, sidebar.x + 18, sidebar.y + 48, 11.5, "Categorias do Axia-DE", 0.68, 0.70, 0.74, c.CAIRO_FONT_WEIGHT_NORMAL);

    for (nav_items, 0..) |item, index| {
        const rect = navItemRect(sidebar, index);
        const active = item.page == current_page;
        const is_hovered = hovered == .nav and hovered.nav == item.page;

        if (active or is_hovered) {
            drawRoundedRect(cr, rect, 12);
            c.cairo_set_source_rgba(cr, if (active) 0.24 else 1.0, if (active) 0.74 else 1.0, if (active) 0.92 else 1.0, if (active) 0.18 else 0.06);
            c.cairo_fill(cr);
        }

        const icon_rect = Rect{ .x = rect.x + 12, .y = rect.y + 7, .width = 28, .height = 28 };
        drawRoundedRect(cr, icon_rect, 9);
        c.cairo_set_source_rgba(cr, if (active) 0.25 else 1.0, if (active) 0.75 else 1.0, if (active) 0.94 else 1.0, if (active) 0.22 else 0.05);
        c.cairo_fill(cr);
        drawCenteredLabel(cr, icon_rect, 13, item.icon, if (active) 0.25 else 0.84, if (active) 0.83 else 0.86, if (active) 0.95 else 0.90);

        drawLabel(cr, rect.x + 50, rect.y + 26, 14, item.label, if (active) 0.40 else 0.93, if (active) 0.86 else 0.94, if (active) 0.98 else 0.96, if (active) c.CAIRO_FONT_WEIGHT_BOLD else c.CAIRO_FONT_WEIGHT_NORMAL);
    }
}

fn drawContent(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = contentRect(width, height);
    const heading = pageHeading(state.page);
    drawLabel(cr, content.x, content.y + 26, 24, heading.title, 0.97, 0.98, 0.99, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, content.x, content.y + 48, 13, heading.subtitle, 0.70, 0.73, 0.78, c.CAIRO_FONT_WEIGHT_NORMAL);

    switch (state.page) {
        .wallpapers => drawWallpaperPage(cr, width, height, state),
        else => drawPlaceholderPage(cr, content, state.page),
    }
}

fn drawWallpaperPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = contentRect(width, height);
    drawLabel(cr, content.x, content.y + 82, 15, "Escolha um preset ou navegue pelos arquivos locais.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);

    for (settings_model.wallpaper_presets, 0..) |preset, index| {
        const rect = wallpaperCardRect(width, height, index);
        const active = state.current_wallpaper_path != null and std.mem.eql(u8, state.current_wallpaper_path.?, preset.path);
        const is_hovered = state.hovered == .wallpaper_preset and state.hovered.wallpaper_preset == index;
        drawRoundedRect(cr, rect, 16);
        if (active) {
            c.cairo_set_source_rgba(cr, 0.18, 0.47, 0.61, 0.94);
        } else if (is_hovered) {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.075);
        } else {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.035);
        }
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (active) 0.18 else 0.06);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        const preview = Rect{ .x = rect.x + 14, .y = rect.y + 14, .width = rect.width - 28, .height = 80 };
        drawWallpaperPreview(cr, preview, preset.colors);
        if (active) drawBadge(cr, .{ .x = rect.x + rect.width - 72, .y = rect.y + 16, .width = 46, .height = 20 }, "Ativo");
        drawLabel(cr, rect.x + 14, rect.y + 118, 15, preset.label, 0.95, 0.96, 0.97, c.CAIRO_FONT_WEIGHT_BOLD);
        drawLabel(cr, rect.x + 14, rect.y + 138, 12, preset.description, 0.74, 0.76, 0.80, c.CAIRO_FONT_WEIGHT_NORMAL);
    }

    if (state.current_wallpaper_path) |path| {
        drawLabel(cr, content.x, content.y + 280, 13, "Wallpaper atual", 0.88, 0.89, 0.92, c.CAIRO_FONT_WEIGHT_BOLD);
        drawPathChip(cr, .{ .x = content.x, .y = content.y + 292, .width = content.width, .height = 40 }, path);
    }

    drawBrowser(cr, width, height, state.browser, state.hovered);
}

fn drawPlaceholderPage(cr: *c.cairo_t, content: Rect, page: settings_model.Page) void {
    const card = Rect{ .x = content.x, .y = content.y + 82, .width = content.width, .height = 220 };
    drawRoundedRect(cr, card, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_fill(cr);
    drawLabel(cr, card.x + 24, card.y + 54, 18, "Em construção", 0.96, 0.97, 0.98, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, card.x + 24, card.y + 84, 14.5, placeholderText(page), 0.78, 0.80, 0.84, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawBrowser(cr: *c.cairo_t, width: u32, height: u32, snapshot: settings_files.Snapshot, hovered: Hit) void {
    const rect = browserPanelRect(width, height);
    drawRoundedRect(cr, rect, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
    c.cairo_fill(cr);

    drawLabel(cr, rect.x + 16, rect.y + 24, 15, "Arquivos locais", 0.93, 0.94, 0.96, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, rect.x + 16, rect.y + 42, 12, "Pastas primeiro, imagens depois. Clique na imagem para aplicar.", 0.70, 0.73, 0.77, c.CAIRO_FONT_WEIGHT_NORMAL);

    drawMiniButton(cr, browserHomeRect(width, height), "Início", hovered == .browser_home);
    drawMiniButton(cr, browserPicturesRect(width, height), "Imagens", hovered == .browser_pictures);
    drawMiniButton(cr, browserDownloadsRect(width, height), "Downloads", hovered == .browser_downloads);
    drawMiniButton(cr, browserUpRect(width, height), "Subir", hovered == .browser_up);

    drawLabel(cr, rect.x + 16, rect.y + 86, 12, "Pasta atual", 0.82, 0.84, 0.88, c.CAIRO_FONT_WEIGHT_BOLD);
    drawPathChip(cr, .{ .x = rect.x + 104, .y = rect.y + 66, .width = rect.width - 120, .height = 30 }, snapshot.current_dir);

    for (0..snapshot.count) |index| {
        const entry_rect = browserEntryRect(width, height, index);
        const entry = snapshot.entries[index];
        const is_hovered = hovered == .browser_entry and hovered.browser_entry == index;

        drawRoundedRect(cr, entry_rect, 8);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (is_hovered) 0.08 else 0.04);
        c.cairo_fill(cr);

        drawLabel(cr, entry_rect.x + 12, entry_rect.y + 18, 11.5, switch (entry.kind) {
            .directory => "Pasta",
            .image => "Imagem",
        }, if (entry.kind == .directory) 0.48 else 0.42, 0.82, 0.98, c.CAIRO_FONT_WEIGHT_BOLD);
        drawLabel(cr, entry_rect.x + 66, entry_rect.y + 18, 12.5, entry.text(), 0.90, 0.91, 0.93, c.CAIRO_FONT_WEIGHT_NORMAL);
        drawLabel(cr, entry_rect.x + entry_rect.width - 42, entry_rect.y + 18, 11.5, switch (entry.kind) {
            .directory => "Abrir",
            .image => "Usar",
        }, 0.60, 0.80, 0.94, c.CAIRO_FONT_WEIGHT_BOLD);
    }

    drawMiniButton(cr, browserPrevRect(width, height), "<", snapshot.has_previous and hovered == .browser_prev);
    drawMiniButton(cr, browserNextRect(width, height), ">", snapshot.has_next and hovered == .browser_next);

    var footer_buf: [64]u8 = undefined;
    const start_index: usize = if (snapshot.total_count == 0) 0 else snapshot.page_start + 1;
    const end_index: usize = if (snapshot.total_count == 0) 0 else snapshot.page_start + snapshot.count;
    const footer = std.fmt.bufPrint(&footer_buf, "{d}-{d} de {d}", .{ start_index, end_index, snapshot.total_count }) catch "";
    drawLabel(cr, rect.x + rect.width - 132, rect.y + rect.height - 14, 11.5, footer, 0.66, 0.69, 0.73, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn rootRect(width: u32, height: u32) Rect {
    return chrome.rootRect(width, height);
}

fn sidebarRect(width: u32, height: u32) Rect {
    const root = rootRect(width, height);
    return .{
        .x = root.x + 14,
        .y = root.y + titlebar_height + 12,
        .width = sidebar_width,
        .height = root.height - titlebar_height - 26,
    };
}

fn contentRect(width: u32, height: u32) Rect {
    const root = rootRect(width, height);
    const sidebar = sidebarRect(width, height);
    return .{
        .x = sidebar.x + sidebar.width + 24,
        .y = root.y + titlebar_height + 12,
        .width = root.x + root.width - (sidebar.x + sidebar.width + 38),
        .height = root.height - titlebar_height - 26,
    };
}

fn titlebarDragRect(width: u32, height: u32) Rect {
    return chrome.titlebarDragRect(width, height, 120, 120);
}

fn navItemRect(sidebar: Rect, index: usize) Rect {
    return .{
        .x = sidebar.x + 10,
        .y = sidebar.y + 64 + @as(f64, @floatFromInt(index)) * 42,
        .width = sidebar.width - 20,
        .height = 32,
    };
}

fn wallpaperCardRect(width: u32, height: u32, index: usize) Rect {
    const content = contentRect(width, height);
    return .{
        .x = content.x + @as(f64, @floatFromInt(index)) * (preset_card_width + preset_gap),
        .y = content.y + 102,
        .width = preset_card_width,
        .height = preset_card_height,
    };
}

fn browserPanelRect(width: u32, height: u32) Rect {
    const content = contentRect(width, height);
    return .{
        .x = content.x,
        .y = content.y + 350,
        .width = content.width,
        .height = 260,
    };
}

fn browserHomeRect(width: u32, height: u32) Rect {
    const rect = browserPanelRect(width, height);
    return .{ .x = rect.x + 16, .y = rect.y + 52, .width = 78, .height = 28 };
}

fn browserPicturesRect(width: u32, height: u32) Rect {
    const rect = browserPanelRect(width, height);
    return .{ .x = rect.x + 102, .y = rect.y + 52, .width = 88, .height = 28 };
}

fn browserDownloadsRect(width: u32, height: u32) Rect {
    const rect = browserPanelRect(width, height);
    return .{ .x = rect.x + 198, .y = rect.y + 52, .width = 98, .height = 28 };
}

fn browserUpRect(width: u32, height: u32) Rect {
    const rect = browserPanelRect(width, height);
    return .{ .x = rect.x + rect.width - 94, .y = rect.y + 52, .width = 78, .height = 28 };
}

fn browserPrevRect(width: u32, height: u32) Rect {
    const rect = browserPanelRect(width, height);
    return .{ .x = rect.x + rect.width - 80, .y = rect.y + rect.height - 34, .width = 28, .height = 24 };
}

fn browserNextRect(width: u32, height: u32) Rect {
    const rect = browserPanelRect(width, height);
    return .{ .x = rect.x + rect.width - 44, .y = rect.y + rect.height - 34, .width = 28, .height = 24 };
}

fn browserEntryRect(width: u32, height: u32, index: usize) Rect {
    const rect = browserPanelRect(width, height);
    return .{
        .x = rect.x + 16,
        .y = rect.y + 108 + @as(f64, @floatFromInt(index)) * 30,
        .width = rect.width - 32,
        .height = 26,
    };
}

fn minimizeRect(width: u32) Rect {
    return chrome.minimizeRect(width);
}

fn maximizeRect(width: u32) Rect {
    return chrome.maximizeRect(width);
}

fn closeRect(width: u32) Rect {
    return chrome.closeRect(width);
}

fn pageHeading(page: settings_model.Page) struct { title: []const u8, subtitle: []const u8 } {
    return switch (page) {
        .wallpapers => .{ .title = "Papel de Parede", .subtitle = "Presets e seleção local de wallpapers do Axia-DE" },
        .appearance => .{ .title = "Aparência", .subtitle = "Tema, contraste e direção visual do sistema" },
        .panel => .{ .title = "Painel Superior", .subtitle = "Itens, alinhamento e comportamento do topo" },
        .displays => .{ .title = "Monitores", .subtitle = "Saídas, escala e organização de telas" },
        .workspaces => .{ .title = "Áreas de Trabalho", .subtitle = "Fluxo, quantidade e comportamento dos espaços" },
        .network => .{ .title = "Rede", .subtitle = "Wi‑Fi, Ethernet e conectividade do desktop" },
        .bluetooth => .{ .title = "Bluetooth", .subtitle = "Pareamento e dispositivos conectados" },
        .printers => .{ .title = "Impressoras", .subtitle = "Impressão, filas e descoberta de dispositivos" },
        .about => .{ .title = "Sobre o Axia-DE", .subtitle = "Identidade, versão e informações do sistema" },
    };
}

fn placeholderText(page: settings_model.Page) []const u8 {
    return switch (page) {
        .appearance => "Aqui vamos consolidar tema, contraste e variantes visuais.",
        .panel => "Aqui vamos configurar relógio, launcher e widgets do topo.",
        .displays => "Aqui vamos ajustar resolução, escala e layout de monitores.",
        .workspaces => "Aqui vamos controlar áreas de trabalho e regras de navegação.",
        .network => "Aqui vamos mostrar redes disponíveis, status e ajustes de conexão.",
        .bluetooth => "Aqui vamos conectar fones, teclados, mouses e outros acessórios.",
        .printers => "Aqui vamos exibir impressoras, filas e opções de descoberta.",
        .about => "Aqui vai entrar a identidade, versão e informações do Axia-DE.",
        else => "Em breve.",
    };
}

fn drawWallpaperPreview(cr: *c.cairo_t, rect: Rect, colors: [3][4]f64) void {
    drawRoundedRect(cr, rect, 12);
    c.cairo_clip(cr);

    const gradient = c.cairo_pattern_create_linear(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
    defer c.cairo_pattern_destroy(gradient);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.0, colors[0][0], colors[0][1], colors[0][2], colors[0][3]);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.55, colors[1][0], colors[1][1], colors[1][2], colors[1][3]);
    c.cairo_pattern_add_color_stop_rgba(gradient, 1.0, colors[2][0], colors[2][1], colors[2][2], colors[2][3]);
    c.cairo_set_source(cr, gradient);
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
    c.cairo_fill(cr);

    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, 18);
    c.cairo_fill(cr);

    c.cairo_set_source_rgba(cr, 0.45, 0.84, 0.98, 0.45);
    c.cairo_rectangle(cr, rect.x, rect.y + 28, rect.width, 2);
    c.cairo_fill(cr);

    c.cairo_reset_clip(cr);
}

fn drawBadge(cr: *c.cairo_t, rect: Rect, text: []const u8) void {
    drawRoundedRect(cr, rect, 8);
    c.cairo_set_source_rgba(cr, 0.44, 0.86, 0.98, 0.94);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 11.5, text, 0.05, 0.07, 0.10);
}

fn drawPathChip(cr: *c.cairo_t, rect: Rect, text: []const u8) void {
    drawRoundedRect(cr, rect, 14);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill(cr);
    drawLabel(cr, rect.x + 16, rect.y + 25, 12.5, truncateMiddle(text, 92), 0.76, 0.79, 0.83, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawMiniButton(cr: *c.cairo_t, rect: Rect, text: []const u8, hovered: bool) void {
    drawRoundedRect(cr, rect, 8);
    c.cairo_set_source_rgba(cr, 1, 1, 1, if (hovered) 0.10 else 0.06);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 12, text, 0.84, 0.85, 0.87);
}

fn hoveredControl(hit: Hit) chrome.HoveredControl {
    return switch (hit) {
        .minimize => .minimize,
        .maximize => .maximize,
        .close => .close,
        else => .none,
    };
}

fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    chrome.drawRoundedRect(cr, rect, radius);
}

fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64, weight: u32) void {
    chrome.drawLabel(cr, x, y, size, text, r, g, b, weight);
}

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    chrome.drawCenteredLabel(cr, rect, size, text, r, g, b);
}

fn truncateMiddle(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    if (max_len <= 3) return text[0..max_len];
    return text[0 .. max_len - 3];
}
