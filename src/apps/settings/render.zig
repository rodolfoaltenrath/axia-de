const std = @import("std");
const c = @import("client_wl").c;
const chrome = @import("client_chrome");
const settings_model = @import("settings_model");

pub const window_width: u32 = 1040;
pub const window_height: u32 = 760;

const titlebar_height = chrome.titlebar_height;
const sidebar_width = 228.0;
const preset_card_width = 204.0;
const preset_card_height = 152.0;
const preset_gap = 16.0;
const accent_card_width = 176.0;
const accent_card_height = 126.0;
const toggle_card_height = 78.0;
const scroll_gutter_width = 16.0;
const scroll_track_width = 8.0;
const scroll_corner_radius = 4.0;

pub const Rect = chrome.Rect;
pub const Hit = settings_model.Hit;

pub const State = struct {
    page: settings_model.Page,
    hovered: Hit = .none,
    current_wallpaper_path: ?[]const u8 = null,
    preferences: settings_model.PreferencesState = .{},
    runtime: settings_model.RuntimeState = .{},
    scroll_y: f64 = 0,
};

const NavItem = struct {
    page: settings_model.Page,
    label: []const u8,
};

const nav_items = [_]NavItem{
    .{ .page = .wallpapers, .label = "Papel de Parede" },
    .{ .page = .appearance, .label = "Aparência" },
    .{ .page = .panel, .label = "Painel Superior" },
    .{ .page = .dock, .label = "Dock" },
    .{ .page = .displays, .label = "Monitores" },
    .{ .page = .workspaces, .label = "Áreas de Trabalho" },
    .{ .page = .network, .label = "Rede" },
    .{ .page = .bluetooth, .label = "Bluetooth" },
    .{ .page = .printers, .label = "Impressoras" },
    .{ .page = .about, .label = "Sobre" },
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

    if (maxScroll(width, height, state) > 0.5) {
        if (scrollThumbRect(width, height, state).contains(x, y)) return .scroll_thumb;
        if (scrollTrackRect(width, height).contains(x, y)) return .scroll_track;
    }

    const viewport = scrollViewportRect(width, height);
    const hit_y = if (viewport.contains(x, y)) y + state.scroll_y else y;

    if (state.page == .wallpapers) {
        for (settings_model.wallpaper_presets, 0..) |_, index| {
            if (wallpaperCardRect(width, height, index).contains(x, hit_y)) return .{ .wallpaper_preset = index };
        }
        if (manualPickerButtonRect(width, height).contains(x, hit_y)) return .browser_manual;
    }

    if (state.page == .appearance) {
        for (settings_model.accent_presets) |accent| {
            if (accentCardRect(width, height, accent.preset).contains(x, hit_y)) return .{ .accent_preset = accent.preset };
        }
        if (reduceTransparencyRect(width, height).contains(x, hit_y)) return .reduce_transparency;
    }

    if (state.page == .panel) {
        if (panelSecondsRect(width, height).contains(x, hit_y)) return .panel_show_seconds;
        if (panelDateRect(width, height).contains(x, hit_y)) return .panel_show_date;
    }

    if (state.page == .dock) {
        for (settings_model.dock_size_options, 0..) |option, index| {
            if (dockSizeChipRect(width, height, index).contains(x, hit_y)) return .{ .dock_size = option.preset };
        }
        for (settings_model.dock_icon_size_options, 0..) |option, index| {
            if (dockIconChipRect(width, height, index).contains(x, hit_y)) return .{ .dock_icon_size = option.preset };
        }
        if (dockAutoHideRect(width, height).contains(x, hit_y)) return .dock_auto_hide;
        if (dockStrongHoverRect(width, height).contains(x, hit_y)) return .dock_strong_hover;
    }

    if (state.page == .workspaces) {
        if (workspaceWrapRect(width, height).contains(x, hit_y)) return .workspace_wrap;
        for (0..state.runtime.workspace_count) |index| {
            if (startupWorkspaceRect(width, height, index).contains(x, hit_y)) return .{ .startup_workspace = index };
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
        .accent_glyph = "",
        .title_x = 56,
    }, hoveredControl(state.hovered));
    drawTopSettingsIcon(cr);
    drawSidebar(cr, width, height, state.page, state.hovered);
    drawContent(cr, width, height, state);
}

fn drawSidebar(cr: *c.cairo_t, width: u32, height: u32, current_page: settings_model.Page, hovered: Hit) void {
    const sidebar = sidebarRect(width, height);
    drawRoundedRect(cr, sidebar, 18);
    c.cairo_set_source_rgba(cr, 0.10, 0.105, 0.12, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.055);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    for (nav_items, 0..) |item, index| {
        const rect = navItemRect(sidebar, index);
        const active = item.page == current_page;
        const is_hovered = hovered == .nav and hovered.nav == item.page;

        if (active or is_hovered) {
            drawRoundedRect(cr, rect, 12);
            c.cairo_set_source_rgba(cr, if (active) 0.20 else 1.0, if (active) 0.56 else 1.0, if (active) 0.68 else 1.0, if (active) 0.26 else 0.055);
            c.cairo_fill(cr);
        }

        if (active) {
            const accent_rect = Rect{ .x = rect.x + 6, .y = rect.y + 6, .width = 4, .height = rect.height - 12 };
            drawRoundedRect(cr, accent_rect, 2);
            c.cairo_set_source_rgba(cr, 0.40, 0.88, 0.98, 0.96);
            c.cairo_fill(cr);
        }

        const icon_rect = Rect{
            .x = rect.x + 14,
            .y = rect.y + (rect.height - 30) / 2.0,
            .width = 30,
            .height = 30,
        };
        drawRoundedRect(cr, icon_rect, 10);
        c.cairo_set_source_rgba(cr, if (active) 0.22 else 1.0, if (active) 0.62 else 1.0, if (active) 0.78 else 1.0, if (active) 0.20 else 0.045);
        c.cairo_fill(cr);
        drawSettingsNavIcon(
            cr,
            icon_rect,
            item.page,
            if (active) .{ 0.26, 0.86, 0.98 } else .{ 0.82, 0.84, 0.88 },
            active,
        );

        drawLabel(cr, rect.x + 54, rect.y + 23, 14, item.label, if (active) 0.42 else 0.93, if (active) 0.88 else 0.94, if (active) 0.98 else 0.96, if (active) c.CAIRO_FONT_WEIGHT_BOLD else c.CAIRO_FONT_WEIGHT_NORMAL);
    }
}

fn drawContent(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = contentRect(width, height);
    const heading = pageHeading(state.page);
    drawLabel(cr, content.x, content.y + 26, 24, heading.title, 0.97, 0.98, 0.99, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, content.x, content.y + 48, 13, heading.subtitle, 0.70, 0.73, 0.78, c.CAIRO_FONT_WEIGHT_NORMAL);

    const viewport = scrollViewportRect(width, height);
    c.cairo_save(cr);
    drawRoundedRect(cr, viewport, 18);
    c.cairo_clip(cr);
    c.cairo_translate(cr, 0, -state.scroll_y);

    switch (state.page) {
        .wallpapers => drawWallpaperPage(cr, width, height, state),
        .appearance => drawAppearancePage(cr, width, height, state),
        .panel => drawPanelPage(cr, width, height, state),
        .dock => drawDockPage(cr, width, height, state),
        .displays => drawDisplaysPage(cr, width, height, state),
        .workspaces => drawWorkspacesPage(cr, width, height, state),
        .about => drawAboutPage(cr, width, height, state),
        else => drawPlaceholderPage(cr, content, state.page),
    }
    c.cairo_restore(cr);

    drawScrollBar(cr, width, height, state);
}

fn drawWallpaperPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
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

    drawManualPickerCard(cr, width, height, state.hovered);
}

fn drawAppearancePage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = contentRect(width, height);
    drawLabel(cr, content.x, content.y + 82, 15, "Escolha a cor de destaque e ajuste a transparência do sistema.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);
    drawLabel(cr, content.x, content.y + 118, 13, "Cor de destaque", 0.91, 0.93, 0.95, c.CAIRO_FONT_WEIGHT_BOLD);

    for (settings_model.accent_presets) |accent| {
        const rect = accentCardRect(width, height, accent.preset);
        const selected = state.preferences.accent == accent.preset;
        const hovered = state.hovered == .accent_preset and state.hovered.accent_preset == accent.preset;
        drawSelectionCard(cr, rect, accent.label, accent.description, selected, hovered, accent.primary, accent.secondary);
    }

    drawToggleCard(
        cr,
        reduceTransparencyRect(width, height),
        "Reduzir transparência",
        "Diminui o vidro do painel e deixa a leitura mais direta.",
        state.preferences.reduce_transparency,
        state.hovered == .reduce_transparency,
        settings_model.accentSpec(state.preferences.accent).primary,
    );
}

fn drawPanelPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = contentRect(width, height);
    drawLabel(cr, content.x, content.y + 82, 15, "Ajustes do relógio e da leitura rápida no painel superior.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);

    const accent = settings_model.accentSpec(state.preferences.accent).primary;
    drawToggleCard(
        cr,
        panelSecondsRect(width, height),
        "Mostrar segundos no relógio",
        "Atualiza o relógio do topo a cada segundo.",
        state.preferences.panel_show_seconds,
        state.hovered == .panel_show_seconds,
        accent,
    );
    drawToggleCard(
        cr,
        panelDateRect(width, height),
        "Mostrar data junto ao horário",
        "Exibe dia e mês diretamente no painel.",
        state.preferences.panel_show_date,
        state.hovered == .panel_show_date,
        accent,
    );
}

fn drawDockPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = contentRect(width, height);
    const accent = settings_model.accentSpec(state.preferences.accent).primary;
    drawLabel(cr, content.x, content.y + 82, 15, "Tamanho, ícones e comportamento da barra inferior.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);

    drawInfoCard(
        cr,
        .{ .x = content.x, .y = content.y + 112, .width = content.width, .height = 94 },
        "Glass do shell",
        "A dock usa o mesmo efeito de vidro da barra superior e acompanha tamanho e posição em tempo real.",
    );

    drawLabel(cr, content.x, content.y + 236, 13, "Tamanho da dock", 0.91, 0.93, 0.95, c.CAIRO_FONT_WEIGHT_BOLD);
    for (settings_model.dock_size_options, 0..) |option, index| {
        drawChoiceChip(
            cr,
            dockSizeChipRect(width, height, index),
            option.label,
            state.preferences.dock_size == option.preset,
            state.hovered == .dock_size and state.hovered.dock_size == option.preset,
            accent,
        );
    }

    drawLabel(cr, content.x, content.y + 316, 13, "Tamanho dos ícones", 0.91, 0.93, 0.95, c.CAIRO_FONT_WEIGHT_BOLD);
    for (settings_model.dock_icon_size_options, 0..) |option, index| {
        drawChoiceChip(
            cr,
            dockIconChipRect(width, height, index),
            option.label,
            state.preferences.dock_icon_size == option.preset,
            state.hovered == .dock_icon_size and state.hovered.dock_icon_size == option.preset,
            accent,
        );
    }

    drawToggleCard(
        cr,
        dockAutoHideRect(width, height),
        "Ocultar automaticamente",
        "Esconde a dock e mostra novamente quando o mouse volta para a borda inferior.",
        state.preferences.dock_auto_hide,
        state.hovered == .dock_auto_hide,
        accent,
    );
    drawToggleCard(
        cr,
        dockStrongHoverRect(width, height),
        "Hover mais destacado",
        "Realça mais o item ativo e deixa o feedback do ponteiro mais evidente.",
        state.preferences.dock_strong_hover,
        state.hovered == .dock_strong_hover,
        accent,
    );
}

fn drawDisplaysPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = pageBodyContentRect(width, height);
    drawLabel(cr, content.x, content.y + 82, 15, "Monitores detectados pelo compositor nesta sessão.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);

    if (state.runtime.display_count == 0) {
        drawInfoCard(cr, .{ .x = content.x, .y = content.y + 112, .width = content.width, .height = 108 }, "Nenhum monitor listado", "Abra esta tela dentro do Axia-DE para ver as saídas conectadas.");
        return;
    }

    for (0..state.runtime.display_count) |index| {
        const display = state.runtime.displays[index];
        drawDisplayCard(cr, displayCardRect(width, height, index), display);
    }
}

fn drawWorkspacesPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = pageBodyContentRect(width, height);
    drawLabel(cr, content.x, content.y + 82, 15, "Fluxo das áreas de trabalho e espaço inicial da sessão.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);

    var status_buf: [96]u8 = undefined;
    const status = std.fmt.bufPrint(
        &status_buf,
        "Atual: {d} de {d}",
        .{ state.runtime.workspace_current + 1, state.runtime.workspace_count },
    ) catch "Atual";
    drawInfoCard(cr, .{ .x = content.x, .y = content.y + 112, .width = content.width, .height = 88 }, "Estado da sessão", status);

    drawToggleCard(
        cr,
        workspaceWrapRect(width, height),
        "Circular entre workspaces",
        "Quando ativado, a navegação volta para a primeira área depois da última.",
        state.preferences.workspace_wrap,
        state.hovered == .workspace_wrap,
        settings_model.accentSpec(state.preferences.accent).primary,
    );

    drawLabel(cr, content.x, content.y + 330, 13, "Workspace inicial", 0.91, 0.93, 0.95, c.CAIRO_FONT_WEIGHT_BOLD);
    for (0..state.runtime.workspace_count) |index| {
        drawWorkspaceChip(
            cr,
            startupWorkspaceRect(width, height, index),
            index,
            state.preferences.startup_workspace == index,
            state.hovered == .startup_workspace and state.hovered.startup_workspace == index,
            settings_model.accentSpec(state.preferences.accent).primary,
        );
    }
}

fn drawAboutPage(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const content = pageBodyContentRect(width, height);
    drawLabel(cr, content.x, content.y + 82, 15, "Resumo da sessão e da identidade atual do Axia-DE.", 0.85, 0.87, 0.91, c.CAIRO_FONT_WEIGHT_NORMAL);

    var outputs_buf: [64]u8 = undefined;
    const outputs = std.fmt.bufPrint(&outputs_buf, "{d} monitor(es) conectado(s)", .{state.runtime.display_count}) catch "";
    drawInfoCard(cr, .{ .x = content.x, .y = content.y + 112, .width = content.width, .height = 88 }, "Sessão atual", outputs);

    drawInfoCard(
        cr,
        .{ .x = content.x, .y = content.y + 218, .width = content.width, .height = 88 },
        "Socket Wayland",
        if (state.runtime.socketNameText().len > 0) state.runtime.socketNameText() else "indisponível fora da sessão Axia-DE",
    );

    const accent = settings_model.accentSpec(state.preferences.accent);
    drawInfoCard(
        cr,
        .{ .x = content.x, .y = content.y + 324, .width = content.width, .height = 104 },
        "Aparência ativa",
        accent.label,
    );
    drawLabel(cr, content.x + 24, content.y + 398, 12.5, accent.description, 0.74, 0.77, 0.81, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawPlaceholderPage(cr: *c.cairo_t, content: Rect, page: settings_model.Page) void {
    const card = Rect{ .x = content.x, .y = content.y + 82, .width = content.width, .height = 220 };
    drawRoundedRect(cr, card, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_fill(cr);
    drawLabel(cr, card.x + 24, card.y + 54, 18, "Em construção", 0.96, 0.97, 0.98, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, card.x + 24, card.y + 84, 14.5, placeholderText(page), 0.78, 0.80, 0.84, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawManualPickerCard(cr: *c.cairo_t, width: u32, height: u32, hovered: Hit) void {
    const rect = manualPickerCardRect(width, height);
    drawRoundedRect(cr, rect, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
    c.cairo_fill(cr);

    drawLabel(cr, rect.x + 18, rect.y + 30, 15, "Usar minha imagem", 0.93, 0.94, 0.96, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, rect.x + 18, rect.y + 52, 12.5, "Escolha uma foto ou imagem do seu computador.", 0.72, 0.75, 0.79, c.CAIRO_FONT_WEIGHT_NORMAL);
    drawPrimaryButton(cr, manualPickerButtonRect(width, height), "Escolher imagem", hovered == .browser_manual);
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
        .y = sidebar.y + 18 + @as(f64, @floatFromInt(index)) * 42,
        .width = sidebar.width - 20,
        .height = 34,
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

fn manualPickerCardRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{
        .x = content.x,
        .y = content.y + 282,
        .width = content.width,
        .height = 112,
    };
}

fn manualPickerButtonRect(width: u32, height: u32) Rect {
    const rect = manualPickerCardRect(width, height);
    return .{ .x = rect.x + 18, .y = rect.y + 66, .width = 248, .height = 32 };
}

fn accentCardRect(width: u32, height: u32, preset: settings_model.AccentPreset) Rect {
    const content = pageBodyContentRect(width, height);
    const index: usize = switch (preset) {
        .aurora => 0,
        .ember => 1,
        .moss => 2,
    };
    return .{
        .x = content.x + @as(f64, @floatFromInt(index)) * (accent_card_width + 16),
        .y = content.y + 132,
        .width = accent_card_width,
        .height = accent_card_height,
    };
}

fn reduceTransparencyRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{ .x = content.x, .y = content.y + 286, .width = content.width, .height = toggle_card_height };
}

fn panelSecondsRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{ .x = content.x, .y = content.y + 118, .width = content.width, .height = toggle_card_height };
}

fn panelDateRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{ .x = content.x, .y = content.y + 212, .width = content.width, .height = toggle_card_height };
}

fn displayCardRect(width: u32, height: u32, index: usize) Rect {
    const content = pageBodyContentRect(width, height);
    return .{
        .x = content.x,
        .y = content.y + 112 + @as(f64, @floatFromInt(index)) * 102,
        .width = content.width,
        .height = 86,
    };
}

fn dockSizeChipRect(width: u32, height: u32, index: usize) Rect {
    const content = pageBodyContentRect(width, height);
    return .{
        .x = content.x + @as(f64, @floatFromInt(index)) * 124,
        .y = content.y + 250,
        .width = 108,
        .height = 36,
    };
}

fn dockIconChipRect(width: u32, height: u32, index: usize) Rect {
    const content = pageBodyContentRect(width, height);
    return .{
        .x = content.x + @as(f64, @floatFromInt(index)) * 124,
        .y = content.y + 330,
        .width = 108,
        .height = 36,
    };
}

fn dockAutoHideRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{ .x = content.x, .y = content.y + 392, .width = content.width, .height = toggle_card_height };
}

fn dockStrongHoverRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{ .x = content.x, .y = content.y + 486, .width = content.width, .height = toggle_card_height };
}

fn workspaceWrapRect(width: u32, height: u32) Rect {
    const content = pageBodyContentRect(width, height);
    return .{ .x = content.x, .y = content.y + 220, .width = content.width, .height = toggle_card_height };
}

fn startupWorkspaceRect(width: u32, height: u32, index: usize) Rect {
    const content = pageBodyContentRect(width, height);
    return .{
        .x = content.x + @as(f64, @floatFromInt(index)) * 58,
        .y = content.y + 344,
        .width = 46,
        .height = 34,
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

pub fn scrollViewportRect(width: u32, height: u32) Rect {
    const content = contentRect(width, height);
    return .{
        .x = content.x,
        .y = content.y + 72,
        .width = content.width,
        .height = content.height - 82,
    };
}

pub fn maxScroll(width: u32, height: u32, state: State) f64 {
    const viewport = scrollViewportRect(width, height);
    const content_height = pageContentHeight(width, height, state);
    return @max(0.0, content_height - viewport.height);
}

fn pageBodyContentRect(width: u32, height: u32) Rect {
    const viewport = scrollViewportRect(width, height);
    return .{
        .x = viewport.x,
        .y = viewport.y - 72,
        .width = viewport.width - scroll_gutter_width,
        .height = viewport.height + 72,
    };
}

pub fn scrollTrackRect(width: u32, height: u32) Rect {
    const viewport = scrollViewportRect(width, height);
    return .{
        .x = viewport.x + viewport.width - scroll_track_width,
        .y = viewport.y + 8,
        .width = scroll_track_width,
        .height = viewport.height - 16,
    };
}

fn drawScrollBar(cr: *c.cairo_t, width: u32, height: u32, state: State) void {
    const max_scroll = maxScroll(width, height, state);
    if (max_scroll <= 0.5) return;

    const viewport = scrollViewportRect(width, height);
    const track = scrollTrackRect(width, height);
    const thumb = scrollThumbRect(width, height, state);

    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    drawRoundedRect(cr, .{ .x = viewport.x + viewport.width - scroll_gutter_width, .y = viewport.y, .width = scroll_gutter_width, .height = viewport.height }, 10);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.025);
    c.cairo_fill(cr);

    drawRoundedRect(cr, track, scroll_corner_radius);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
    c.cairo_fill(cr);

    drawRoundedRect(cr, thumb, scroll_corner_radius);
    c.cairo_set_source_rgba(cr, 0.36, 0.78, 0.92, 0.78);
    c.cairo_fill(cr);
}

pub fn scrollThumbRect(width: u32, height: u32, state: State) Rect {
    const track = scrollTrackRect(width, height);
    const viewport = scrollViewportRect(width, height);
    const content_height = pageContentHeight(width, height, state);
    const max_scroll = @max(0.0, content_height - viewport.height);
    const min_thumb_height = 44.0;
    const thumb_height = std.math.clamp((viewport.height / content_height) * track.height, min_thumb_height, track.height);
    const available = @max(0.0, track.height - thumb_height);
    const progress = if (max_scroll <= 0.0) 0.0 else state.scroll_y / max_scroll;
    return .{
        .x = track.x,
        .y = track.y + available * progress,
        .width = track.width,
        .height = thumb_height,
    };
}

fn pageContentHeight(width: u32, height: u32, state: State) f64 {
    const viewport = scrollViewportRect(width, height);
    const bottom = switch (state.page) {
        .wallpapers => manualPickerCardRect(width, height).y + manualPickerCardRect(width, height).height + 20,
        .appearance => reduceTransparencyRect(width, height).y + reduceTransparencyRect(width, height).height + 20,
        .panel => panelDateRect(width, height).y + panelDateRect(width, height).height + 20,
        .dock => dockStrongHoverRect(width, height).y + dockStrongHoverRect(width, height).height + 20,
        .displays => blk: {
            if (state.runtime.display_count == 0) {
                break :blk viewport.y + 240;
            }
            const last_index = state.runtime.display_count - 1;
            const rect = displayCardRect(width, height, last_index);
            break :blk rect.y + rect.height + 20;
        },
        .workspaces => blk: {
            const last_chip = if (state.runtime.workspace_count == 0)
                viewport.y + 380
            else blk2: {
                const rect = startupWorkspaceRect(width, height, state.runtime.workspace_count - 1);
                break :blk2 rect.y + rect.height;
            };
            break :blk last_chip + 28;
        },
        .about => pageBodyContentRect(width, height).y + 430,
        else => pageBodyContentRect(width, height).y + 320,
    };
    return @max(viewport.height, bottom - viewport.y);
}

fn pageHeading(page: settings_model.Page) struct { title: []const u8, subtitle: []const u8 } {
    return switch (page) {
        .wallpapers => .{ .title = "Papel de Parede", .subtitle = "Escolha o fundo da sua área de trabalho" },
        .appearance => .{ .title = "Aparência", .subtitle = "Tema, contraste e direção visual do sistema" },
        .panel => .{ .title = "Painel Superior", .subtitle = "Itens, alinhamento e comportamento do topo" },
        .dock => .{ .title = "Dock", .subtitle = "Tamanho, ícones e comportamento da barra inferior" },
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
        .dock => "Aqui vamos controlar tamanho, ícones e comportamento da dock.",
        .displays => "Aqui vamos ajustar resolução, escala e layout de monitores.",
        .workspaces => "Aqui vamos controlar áreas de trabalho e regras de navegação.",
        .network => "Aqui vamos mostrar redes disponíveis, status e ajustes de conexão.",
        .bluetooth => "Aqui vamos conectar fones, teclados, mouses e outros acessórios.",
        .printers => "Aqui vamos exibir impressoras, filas e opções de descoberta.",
        .about => "Aqui vai entrar a identidade, versão e informações do Axia-DE.",
        else => "Em breve.",
    };
}

fn drawSelectionCard(
    cr: *c.cairo_t,
    rect: Rect,
    title: []const u8,
    description: []const u8,
    selected: bool,
    hovered: bool,
    primary: [3]f64,
    secondary: [3]f64,
) void {
    drawRoundedRect(cr, rect, 16);
    if (selected) {
        c.cairo_set_source_rgba(cr, secondary[0], secondary[1], secondary[2], 0.92);
    } else if (hovered) {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.07);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.035);
    }
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, if (selected) 0.18 else 0.06);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    drawWallpaperPreview(cr, .{ .x = rect.x + 14, .y = rect.y + 14, .width = rect.width - 28, .height = 54 }, .{
        .{ secondary[0], secondary[1], secondary[2], 1.0 },
        .{ primary[0], primary[1], primary[2], 1.0 },
        .{ 0.98, 0.98, 0.99, 1.0 },
    });
    drawLabel(cr, rect.x + 14, rect.y + 92, 15, title, 0.95, 0.96, 0.97, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, rect.x + 14, rect.y + 112, 11.5, description, 0.74, 0.76, 0.80, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawToggleCard(
    cr: *c.cairo_t,
    rect: Rect,
    title: []const u8,
    description: []const u8,
    enabled: bool,
    hovered: bool,
    accent: [3]f64,
) void {
    drawRoundedRect(cr, rect, 16);
    c.cairo_set_source_rgba(cr, 1, 1, 1, if (hovered) 0.07 else 0.04);
    c.cairo_fill(cr);

    drawLabel(cr, rect.x + 18, rect.y + 30, 15, title, 0.95, 0.96, 0.97, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, rect.x + 18, rect.y + 52, 12.5, description, 0.74, 0.77, 0.81, c.CAIRO_FONT_WEIGHT_NORMAL);

    const switch_rect = Rect{ .x = rect.x + rect.width - 84, .y = rect.y + 22, .width = 52, .height = 28 };
    drawRoundedRect(cr, switch_rect, 14);
    if (enabled) {
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.92);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    }
    c.cairo_fill(cr);

    const knob_x = if (enabled) switch_rect.x + 28 else switch_rect.x + 4;
    drawRoundedRect(cr, .{ .x = knob_x, .y = switch_rect.y + 4, .width = 20, .height = 20 }, 10);
    c.cairo_set_source_rgba(cr, 0.98, 0.99, 1.0, 0.96);
    c.cairo_fill(cr);
}

fn drawInfoCard(cr: *c.cairo_t, rect: Rect, title: []const u8, body: []const u8) void {
    drawRoundedRect(cr, rect, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_fill(cr);
    drawLabel(cr, rect.x + 18, rect.y + 28, 14, title, 0.92, 0.94, 0.96, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, rect.x + 18, rect.y + 56, 13.5, truncateMiddle(body, 96), 0.75, 0.78, 0.82, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawDisplayCard(cr: *c.cairo_t, rect: Rect, display: settings_model.DisplayInfo) void {
    drawRoundedRect(cr, rect, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_fill(cr);

    drawLabel(cr, rect.x + 18, rect.y + 30, 14, if (display.nameText().len > 0) display.nameText() else "Saída sem nome", 0.93, 0.95, 0.97, c.CAIRO_FONT_WEIGHT_BOLD);

    var mode_buf: [64]u8 = undefined;
    const mode = std.fmt.bufPrint(&mode_buf, "{d} x {d}", .{ display.width, display.height }) catch "";
    drawLabel(cr, rect.x + 18, rect.y + 56, 13, mode, 0.76, 0.79, 0.83, c.CAIRO_FONT_WEIGHT_NORMAL);

    if (display.primary) {
        drawBadge(cr, .{ .x = rect.x + rect.width - 78, .y = rect.y + 16, .width = 58, .height = 20 }, "Principal");
    }
}

fn drawWorkspaceChip(
    cr: *c.cairo_t,
    rect: Rect,
    index: usize,
    selected: bool,
    hovered: bool,
    accent: [3]f64,
) void {
    drawRoundedRect(cr, rect, 12);
    if (selected) {
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.92);
    } else if (hovered) {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    }
    c.cairo_fill(cr);

    var label_buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{d}", .{index + 1}) catch "?";
    drawCenteredLabel(
        cr,
        rect,
        14,
        label,
        if (selected) 0.08 else 0.92,
        if (selected) 0.10 else 0.94,
        if (selected) 0.12 else 0.96,
    );
}

fn drawChoiceChip(
    cr: *c.cairo_t,
    rect: Rect,
    label: []const u8,
    selected: bool,
    hovered: bool,
    accent: [3]f64,
) void {
    drawRoundedRect(cr, rect, 12);
    if (selected) {
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.92);
    } else if (hovered) {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    }
    c.cairo_fill(cr);
    drawCenteredLabel(
        cr,
        rect,
        13,
        label,
        if (selected) 0.08 else 0.92,
        if (selected) 0.10 else 0.94,
        if (selected) 0.12 else 0.96,
    );
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

fn drawPrimaryButton(cr: *c.cairo_t, rect: Rect, text: []const u8, hovered: bool) void {
    drawRoundedRect(cr, rect, 10);
    c.cairo_set_source_rgba(cr, if (hovered) 0.24 else 0.20, if (hovered) 0.72 else 0.66, if (hovered) 0.92 else 0.86, if (hovered) 0.34 else 0.24);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 12, text, 0.94, 0.97, 0.99);
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

fn drawTopSettingsIcon(cr: *c.cairo_t) void {
    const outer = Rect{ .x = 24, .y = 14, .width = 22, .height = 22 };
    drawRoundedRect(cr, .{ .x = outer.x - 4, .y = outer.y - 3, .width = outer.width + 8, .height = outer.height + 6 }, 11);
    c.cairo_set_source_rgba(cr, 0.20, 0.62, 0.78, 0.18);
    c.cairo_fill(cr);
    drawSettingsNavIcon(cr, outer, .about, .{ 0.36, 0.90, 0.98 }, true);
}

fn drawSettingsNavIcon(
    cr: *c.cairo_t,
    rect: Rect,
    page: settings_model.Page,
    color: [3]f64,
    active: bool,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    const scale = @min(rect.width, rect.height);
    const stroke: f64 = if (active) 1.9 else 1.7;
    c.cairo_set_line_width(cr, stroke);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgb(cr, color[0], color[1], color[2]);

    switch (page) {
        .wallpapers => {
            drawRoundedRect(cr, .{ .x = cx - scale * 0.28, .y = cy - scale * 0.22, .width = scale * 0.56, .height = scale * 0.44 }, 4);
            c.cairo_stroke(cr);
            c.cairo_move_to(cr, cx - scale * 0.20, cy + scale * 0.08);
            c.cairo_line_to(cr, cx - scale * 0.04, cy - scale * 0.06);
            c.cairo_line_to(cr, cx + scale * 0.06, cy + scale * 0.04);
            c.cairo_line_to(cr, cx + scale * 0.20, cy - scale * 0.10);
            c.cairo_stroke(cr);
            c.cairo_arc(cr, cx + scale * 0.12, cy - scale * 0.08, scale * 0.04, 0, std.math.tau);
            c.cairo_fill(cr);
        },
        .appearance => {
            c.cairo_arc(cr, cx - scale * 0.02, cy + scale * 0.02, scale * 0.14, 0, std.math.tau);
            c.cairo_stroke(cr);
            c.cairo_arc(cr, cx + scale * 0.10, cy - scale * 0.10, scale * 0.05, 0, std.math.tau);
            c.cairo_fill(cr);
            c.cairo_move_to(cr, cx - scale * 0.18, cy + scale * 0.16);
            c.cairo_curve_to(cr, cx - scale * 0.06, cy + scale * 0.26, cx + scale * 0.12, cy + scale * 0.24, cx + scale * 0.20, cy + scale * 0.08);
            c.cairo_stroke(cr);
        },
        .panel => {
            drawRoundedRect(cr, .{ .x = cx - scale * 0.26, .y = cy - scale * 0.18, .width = scale * 0.52, .height = scale * 0.36 }, 4);
            c.cairo_stroke(cr);
            c.cairo_move_to(cr, cx - scale * 0.18, cy - scale * 0.05);
            c.cairo_line_to(cr, cx + scale * 0.18, cy - scale * 0.05);
            c.cairo_move_to(cr, cx - scale * 0.18, cy + scale * 0.05);
            c.cairo_line_to(cr, cx - scale * 0.02, cy + scale * 0.05);
            c.cairo_stroke(cr);
        },
        .dock => {
            drawRoundedRect(cr, .{ .x = cx - scale * 0.28, .y = cy - scale * 0.04, .width = scale * 0.56, .height = scale * 0.22 }, 4);
            c.cairo_stroke(cr);
            c.cairo_arc(cr, cx - scale * 0.14, cy + scale * 0.12, scale * 0.03, 0, std.math.tau);
            c.cairo_fill(cr);
            c.cairo_arc(cr, cx, cy + scale * 0.12, scale * 0.03, 0, std.math.tau);
            c.cairo_fill(cr);
            c.cairo_arc(cr, cx + scale * 0.14, cy + scale * 0.12, scale * 0.03, 0, std.math.tau);
            c.cairo_fill(cr);
        },
        .displays => {
            drawRoundedRect(cr, .{ .x = cx - scale * 0.28, .y = cy - scale * 0.18, .width = scale * 0.34, .height = scale * 0.24 }, 3);
            c.cairo_stroke(cr);
            drawRoundedRect(cr, .{ .x = cx - scale * 0.02, .y = cy - scale * 0.08, .width = scale * 0.24, .height = scale * 0.18 }, 3);
            c.cairo_stroke(cr);
            c.cairo_move_to(cr, cx - scale * 0.18, cy + scale * 0.12);
            c.cairo_line_to(cr, cx - scale * 0.04, cy + scale * 0.12);
            c.cairo_move_to(cr, cx + scale * 0.06, cy + scale * 0.14);
            c.cairo_line_to(cr, cx + scale * 0.18, cy + scale * 0.14);
            c.cairo_stroke(cr);
        },
        .workspaces => {
            inline for (0..2) |row| {
                inline for (0..2) |col| {
                    drawRoundedRect(cr, .{
                        .x = cx - scale * 0.22 + @as(f64, @floatFromInt(col)) * scale * 0.18,
                        .y = cy - scale * 0.18 + @as(f64, @floatFromInt(row)) * scale * 0.18,
                        .width = scale * 0.12,
                        .height = scale * 0.12,
                    }, 2);
                    c.cairo_stroke(cr);
                }
            }
        },
        .network => {
            c.cairo_arc(cr, cx, cy + scale * 0.06, scale * 0.06, 0, std.math.tau);
            c.cairo_fill(cr);
            c.cairo_arc(cr, cx, cy + scale * 0.06, scale * 0.14, -2.5, -0.64);
            c.cairo_stroke(cr);
            c.cairo_arc(cr, cx, cy + scale * 0.06, scale * 0.22, -2.5, -0.64);
            c.cairo_stroke(cr);
        },
        .bluetooth => {
            c.cairo_move_to(cr, cx - scale * 0.02, cy - scale * 0.24);
            c.cairo_line_to(cr, cx - scale * 0.02, cy + scale * 0.24);
            c.cairo_line_to(cr, cx + scale * 0.16, cy + scale * 0.08);
            c.cairo_line_to(cr, cx - scale * 0.02, cy - scale * 0.04);
            c.cairo_line_to(cr, cx + scale * 0.16, cy - scale * 0.18);
            c.cairo_line_to(cr, cx - scale * 0.02, cy - scale * 0.24);
            c.cairo_stroke(cr);
            c.cairo_move_to(cr, cx - scale * 0.18, cy - scale * 0.12);
            c.cairo_line_to(cr, cx + scale * 0.04, cy + scale * 0.02);
            c.cairo_move_to(cr, cx - scale * 0.18, cy + scale * 0.16);
            c.cairo_line_to(cr, cx + scale * 0.04, cy + scale * 0.02);
            c.cairo_stroke(cr);
        },
        .printers => {
            drawRoundedRect(cr, .{ .x = cx - scale * 0.20, .y = cy - scale * 0.20, .width = scale * 0.40, .height = scale * 0.14 }, 3);
            c.cairo_stroke(cr);
            drawRoundedRect(cr, .{ .x = cx - scale * 0.24, .y = cy - scale * 0.06, .width = scale * 0.48, .height = scale * 0.18 }, 3);
            c.cairo_stroke(cr);
            drawRoundedRect(cr, .{ .x = cx - scale * 0.16, .y = cy + scale * 0.08, .width = scale * 0.32, .height = scale * 0.16 }, 3);
            c.cairo_stroke(cr);
        },
        .about => {
            c.cairo_arc(cr, cx, cy, scale * 0.22, 0, std.math.tau);
            c.cairo_stroke(cr);
            c.cairo_arc(cr, cx, cy - scale * 0.10, scale * 0.03, 0, std.math.tau);
            c.cairo_fill(cr);
            c.cairo_move_to(cr, cx, cy - scale * 0.02);
            c.cairo_line_to(cr, cx, cy + scale * 0.12);
            c.cairo_stroke(cr);
        },
    }
}
