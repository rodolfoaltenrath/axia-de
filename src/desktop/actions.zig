pub const Action = enum {
    wallpapers,
    appearance,
    panel,
    displays,
    workspaces,
    about,
};

pub const Page = enum {
    root,
    personalization,
    system,
    session,
};

pub const ItemKind = enum {
    action,
    navigate,
    separator,
    back,
    disabled,
};

pub const Item = struct {
    kind: ItemKind,
    label: []const u8,
    action: ?Action = null,
    target: ?Page = null,
};

pub const PageSpec = struct {
    title: []const u8,
    subtitle: []const u8,
    items: []const Item,
};

const root_items = [_]Item{
    .{ .kind = .navigate, .label = "Personalização", .target = .personalization },
    .{ .kind = .navigate, .label = "Sistema", .target = .system },
    .{ .kind = .navigate, .label = "Sessão e Janelas", .target = .session },
};

const personalization_items = [_]Item{
    .{ .kind = .back, .label = "Voltar" },
    .{ .kind = .action, .label = "Papel de Parede", .action = .wallpapers },
    .{ .kind = .action, .label = "Aparência", .action = .appearance },
    .{ .kind = .action, .label = "Painel Superior", .action = .panel },
};

const system_items = [_]Item{
    .{ .kind = .back, .label = "Voltar" },
    .{ .kind = .action, .label = "Monitores", .action = .displays },
    .{ .kind = .action, .label = "Áreas de Trabalho", .action = .workspaces },
    .{ .kind = .action, .label = "Sobre o Axia-DE", .action = .about },
};

const session_items = [_]Item{
    .{ .kind = .back, .label = "Voltar" },
    .{ .kind = .disabled, .label = "Atalhos Globais (em breve)" },
    .{ .kind = .disabled, .label = "Comportamento de Janelas (em breve)" },
    .{ .kind = .disabled, .label = "Aplicativos de Sessão (em breve)" },
};

pub fn specFor(page: Page) PageSpec {
    return switch (page) {
        .root => .{
            .title = "Desktop",
            .subtitle = "Navegação de configurações do Axia-DE",
            .items = root_items[0..],
        },
        .personalization => .{
            .title = "Personalização",
            .subtitle = "Visual, painel e identidade do desktop",
            .items = personalization_items[0..],
        },
        .system => .{
            .title = "Sistema",
            .subtitle = "Monitores, workspaces e informações gerais",
            .items = system_items[0..],
        },
        .session => .{
            .title = "Sessão e Janelas",
            .subtitle = "Base para atalhos, regras e comportamento",
            .items = session_items[0..],
        },
    };
}
