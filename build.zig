const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const asset_install_subdir = "share/axia-de/assets";

    // Arch/CachyOS ships wlroots with versioned sonames/includes.
    const wlroots_lib = b.option([]const u8, "wlroots-lib", "wlroots library name") orelse "wlroots-0.18";
    const wlroots_include = b.option([]const u8, "wlroots-include", "wlroots include directory") orelse "/usr/include/wlroots-0.18";
    const xdg_shell_xml = b.option([]const u8, "xdg-shell-xml", "path to xdg-shell.xml") orelse "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const layer_shell_xml = b.option([]const u8, "layer-shell-xml", "path to wlr-layer-shell XML") orelse "protocols/wlr-layer-shell-unstable-v1.xml";
    const ext_workspace_xml = b.option([]const u8, "ext-workspace-xml", "path to ext-workspace-v1.xml") orelse "/usr/share/wayland-protocols/staging/ext-workspace/ext-workspace-v1.xml";
    const cursor_shape_xml = b.option([]const u8, "cursor-shape-xml", "path to cursor-shape-v1.xml") orelse "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml";
    const pointer_constraints_xml = b.option([]const u8, "pointer-constraints-xml", "path to pointer-constraints-unstable-v1.xml") orelse "/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml";
    const relative_pointer_xml = b.option([]const u8, "relative-pointer-xml", "path to relative-pointer-unstable-v1.xml") orelse "/usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml";
    const shortcuts_inhibit_xml = b.option([]const u8, "shortcuts-inhibit-xml", "path to keyboard-shortcuts-inhibit-unstable-v1.xml") orelse "/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml";
    const output_power_xml = b.option([]const u8, "output-power-xml", "path to wlr-output-power-management-unstable-v1.xml") orelse "protocols/wlr-output-power-management-unstable-v1.xml";
    const content_type_xml = b.option([]const u8, "content-type-xml", "path to content-type-v1.xml") orelse "/usr/share/wayland-protocols/staging/content-type/content-type-v1.xml";
    const tearing_control_xml = b.option([]const u8, "tearing-control-xml", "path to tearing-control-v1.xml") orelse "/usr/share/wayland-protocols/staging/tearing-control/tearing-control-v1.xml";

    const gen_xdg_shell = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        xdg_shell_xml,
    });
    const xdg_shell_header = gen_xdg_shell.addOutputFileArg("xdg-shell-protocol.h");

    const gen_xdg_shell_client_header = b.addSystemCommand(&.{
        "wayland-scanner",
        "client-header",
        xdg_shell_xml,
    });
    const xdg_shell_client_header = gen_xdg_shell_client_header.addOutputFileArg("xdg-shell-client-protocol.h");

    const gen_xdg_shell_client_code = b.addSystemCommand(&.{
        "wayland-scanner",
        "private-code",
        xdg_shell_xml,
    });
    const xdg_shell_client_code = gen_xdg_shell_client_code.addOutputFileArg("xdg-shell-protocol.c");

    const gen_layer_shell = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        layer_shell_xml,
    });
    const layer_shell_header = gen_layer_shell.addOutputFileArg("wlr-layer-shell-unstable-v1-protocol.h");


    const gen_ext_workspace = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        ext_workspace_xml,
    });
    const ext_workspace_header = gen_ext_workspace.addOutputFileArg("ext-workspace-v1-protocol.h");

    const gen_ext_workspace_code = b.addSystemCommand(&.{
        "wayland-scanner",
        "private-code",
        ext_workspace_xml,
    });
    const ext_workspace_code = gen_ext_workspace_code.addOutputFileArg("ext-workspace-v1-protocol.c");

    const gen_cursor_shape = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        cursor_shape_xml,
    });
    const cursor_shape_header = gen_cursor_shape.addOutputFileArg("cursor-shape-v1-protocol.h");

    const gen_pointer_constraints = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        pointer_constraints_xml,
    });
    const pointer_constraints_header = gen_pointer_constraints.addOutputFileArg("pointer-constraints-unstable-v1-protocol.h");

    const gen_relative_pointer = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        relative_pointer_xml,
    });
    const relative_pointer_header = gen_relative_pointer.addOutputFileArg("relative-pointer-unstable-v1-protocol.h");

    const gen_shortcuts_inhibit = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        shortcuts_inhibit_xml,
    });
    const shortcuts_inhibit_header = gen_shortcuts_inhibit.addOutputFileArg("keyboard-shortcuts-inhibit-unstable-v1-protocol.h");

    const gen_output_power = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        output_power_xml,
    });
    const output_power_header = gen_output_power.addOutputFileArg("wlr-output-power-management-unstable-v1-protocol.h");

    const gen_content_type = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        content_type_xml,
    });
    const content_type_header = gen_content_type.addOutputFileArg("content-type-v1-protocol.h");

    const gen_tearing_control = b.addSystemCommand(&.{
        "wayland-scanner",
        "server-header",
        tearing_control_xml,
    });
    const tearing_control_header = gen_tearing_control.addOutputFileArg("tearing-control-v1-protocol.h");

    const apps_catalog_module = b.createModule(.{
        .root_source_file = b.path("src/apps/catalog.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_catalog_module = b.createModule(.{
        .root_source_file = b.path("src/apps/runtime_catalog.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_catalog_module.addImport("apps_catalog", apps_catalog_module);
    const assets_module = b.createModule(.{
        .root_source_file = b.path("src/assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    const client_wl_module = b.createModule(.{
        .root_source_file = b.path("src/client/wl.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_wl_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
    client_wl_module.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    client_wl_module.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    client_wl_module.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    client_wl_module.addIncludePath(.{ .cwd_relative = "/usr/include/xkbcommon" });
    client_wl_module.addIncludePath(xdg_shell_client_header.dirname());
    const client_buffer_module = b.createModule(.{
        .root_source_file = b.path("src/client/buffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_buffer_module.addImport("client_wl", client_wl_module);
    const client_chrome_module = b.createModule(.{
        .root_source_file = b.path("src/client/chrome.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_chrome_module.addImport("client_wl", client_wl_module);
    const settings_model_module = b.createModule(.{
        .root_source_file = b.path("src/settings/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const settings_files_module = b.createModule(.{
        .root_source_file = b.path("src/settings/files.zig"),
        .target = target,
        .optimize = optimize,
    });
    const settings_picker_module = b.createModule(.{
        .root_source_file = b.path("src/settings/file_picker.zig"),
        .target = target,
        .optimize = optimize,
    });
    const prefs_module = b.createModule(.{
        .root_source_file = b.path("src/config/preferences.zig"),
        .target = target,
        .optimize = optimize,
    });
    const launcher_state_module = b.createModule(.{
        .root_source_file = b.path("src/config/launcher_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    launcher_state_module.addImport("runtime_catalog", runtime_catalog_module);
    const toast_model_module = b.createModule(.{
        .root_source_file = b.path("src/toast/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const toast_client_module = b.createModule(.{
        .root_source_file = b.path("src/toast/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    toast_client_module.addImport("toast_model", toast_model_module);
    const notification_model_module = b.createModule(.{
        .root_source_file = b.path("src/notification/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const notification_client_module = b.createModule(.{
        .root_source_file = b.path("src/notification/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    notification_client_module.addImport("notification_model", notification_model_module);

    const exe = b.addExecutable(.{
        .name = "axia-de",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    exe.step.dependOn(&gen_xdg_shell.step);
    exe.step.dependOn(&gen_layer_shell.step);
    exe.step.dependOn(&gen_ext_workspace.step);
    exe.step.dependOn(&gen_ext_workspace_code.step);
    exe.step.dependOn(&gen_cursor_shape.step);
    exe.step.dependOn(&gen_pointer_constraints.step);
    exe.step.dependOn(&gen_relative_pointer.step);
    exe.step.dependOn(&gen_shortcuts_inhibit.step);
    exe.step.dependOn(&gen_output_power.step);
    exe.step.dependOn(&gen_content_type.step);
    exe.step.dependOn(&gen_tearing_control.step);

    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe.addIncludePath(.{ .cwd_relative = wlroots_include });
    exe.addIncludePath(xdg_shell_header.dirname());
    exe.addIncludePath(layer_shell_header.dirname());
    exe.addIncludePath(ext_workspace_header.dirname());
    exe.addIncludePath(cursor_shape_header.dirname());
    exe.addIncludePath(pointer_constraints_header.dirname());
    exe.addIncludePath(relative_pointer_header.dirname());
    exe.addIncludePath(shortcuts_inhibit_header.dirname());
    exe.addIncludePath(output_power_header.dirname());
    exe.addIncludePath(content_type_header.dirname());
    exe.addIncludePath(tearing_control_header.dirname());
    exe.addCSourceFile(.{ .file = ext_workspace_code });

    exe.linkSystemLibrary(wlroots_lib);
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("cairo");

    b.installArtifact(exe);



    const files_app_exe = b.addExecutable(.{
        .name = "axia-files",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/files/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    files_app_exe.linkLibC();
    files_app_exe.root_module.addImport("client_wl", client_wl_module);
    files_app_exe.root_module.addImport("client_buffer", client_buffer_module);
    files_app_exe.root_module.addImport("client_chrome", client_chrome_module);
    files_app_exe.root_module.addImport("toast_model", toast_model_module);
    files_app_exe.root_module.addImport("toast_client", toast_client_module);
    files_app_exe.root_module.addImport("axia_assets", assets_module);
    files_app_exe.step.dependOn(&gen_xdg_shell_client_header.step);
    files_app_exe.step.dependOn(&gen_xdg_shell_client_code.step);
    files_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    files_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    files_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    files_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    files_app_exe.addIncludePath(xdg_shell_client_header.dirname());
    files_app_exe.addCSourceFile(.{ .file = xdg_shell_client_code });
    files_app_exe.linkSystemLibrary("wayland-client");
    files_app_exe.linkSystemLibrary("cairo");
    files_app_exe.linkSystemLibrary("xkbcommon");
    b.installArtifact(files_app_exe);

    const settings_app_exe = b.addExecutable(.{
        .name = "axia-settings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/settings/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    settings_app_exe.linkLibC();
    settings_app_exe.root_module.addImport("client_wl", client_wl_module);
    settings_app_exe.root_module.addImport("client_buffer", client_buffer_module);
    settings_app_exe.root_module.addImport("client_chrome", client_chrome_module);
    settings_app_exe.root_module.addImport("settings_model", settings_model_module);
    settings_app_exe.root_module.addImport("settings_files", settings_files_module);
    settings_app_exe.root_module.addImport("settings_picker", settings_picker_module);
    settings_app_exe.root_module.addImport("axia_prefs", prefs_module);
    settings_app_exe.root_module.addImport("notification_model", notification_model_module);
    settings_app_exe.root_module.addImport("notification_client", notification_client_module);
    settings_app_exe.step.dependOn(&gen_xdg_shell_client_header.step);
    settings_app_exe.step.dependOn(&gen_xdg_shell_client_code.step);
    settings_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    settings_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    settings_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    settings_app_exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    settings_app_exe.addIncludePath(xdg_shell_client_header.dirname());
    settings_app_exe.addCSourceFile(.{ .file = xdg_shell_client_code });
    settings_app_exe.linkSystemLibrary("wayland-client");
    settings_app_exe.linkSystemLibrary("cairo");
    b.installArtifact(settings_app_exe);

    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .prefix,
        .install_subdir = asset_install_subdir,
    });
    b.installDirectory(.{
        .source_dir = b.path("docs"),
        .install_dir = .prefix,
        .install_subdir = "share/doc/axia-de",
        .include_extensions = &.{".md"},
    });
    b.installDirectory(.{
        .source_dir = b.path("packaging/applications"),
        .install_dir = .prefix,
        .install_subdir = "share/applications",
        .include_extensions = &.{".desktop"},
    });
    b.installDirectory(.{
        .source_dir = b.path("packaging/wayland-sessions"),
        .install_dir = .prefix,
        .install_subdir = "share/wayland-sessions",
        .include_extensions = &.{".desktop"},
    });
    b.installBinFile("packaging/bin/axia-session", "axia-session");
    b.installFile("README.md", "share/doc/axia-de/README.md");

    const release_checks_module = b.createModule(.{
        .root_source_file = b.path("tests/release_checks.zig"),
        .target = target,
        .optimize = optimize,
    });
    release_checks_module.addImport("axia_assets", assets_module);
    release_checks_module.addImport("settings_model", settings_model_module);
    const release_checks = b.addTest(.{
        .root_module = release_checks_module,
    });
    const run_release_checks = b.addRunArtifact(release_checks);

    const test_step = b.step("test", "Run Axia-DE release readiness checks");
    test_step.dependOn(&run_release_checks.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Axia-DE");
    run_step.dependOn(&run_cmd.step);

<<<<<<< HEAD
    const run_panel_cmd = b.addRunArtifact(panel_exe);
    run_panel_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_panel_cmd.addArgs(args);
    }

    const run_panel_step = b.step("run-panel", "Run Axia panel client");
    run_panel_step.dependOn(&run_panel_cmd.step);

    const run_dock_cmd = b.addRunArtifact(dock_exe);
    run_dock_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_dock_cmd.addArgs(args);
    }

    const run_dock_step = b.step("run-dock", "Run Axia dock client");
    run_dock_step.dependOn(&run_dock_cmd.step);

    const run_launcher_cmd = b.addRunArtifact(launcher_app_exe);
    run_launcher_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_launcher_cmd.addArgs(args);
    }

    const run_launcher_step = b.step("run-launcher", "Run Axia launcher client");
    run_launcher_step.dependOn(&run_launcher_cmd.step);

    const run_app_grid_cmd = b.addRunArtifact(app_grid_exe);
    run_app_grid_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_app_grid_cmd.addArgs(args);
    }

    const run_app_grid_step = b.step("run-app-grid", "Run Axia app grid client");
    run_app_grid_step.dependOn(&run_app_grid_cmd.step);

    const run_files_cmd = b.addRunArtifact(files_app_exe);
    run_files_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_files_cmd.addArgs(args);
    }

    const run_files_step = b.step("run-files", "Run Axia files app");
    run_files_step.dependOn(&run_files_cmd.step);

    const run_settings_cmd = b.addRunArtifact(settings_app_exe);
    run_settings_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_settings_cmd.addArgs(args);
    }

    const run_settings_step = b.step("run-settings", "Run Axia settings app");
    run_settings_step.dependOn(&run_settings_cmd.step);
=======
>>>>>>> 4b191f5 (refactor: migra shell para arquitetura V2 externa)
}
