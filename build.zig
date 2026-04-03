const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Arch/CachyOS ships wlroots with versioned sonames/includes.
    const wlroots_lib = b.option([]const u8, "wlroots-lib", "wlroots library name") orelse "wlroots-0.18";
    const wlroots_include = b.option([]const u8, "wlroots-include", "wlroots include directory") orelse "/usr/include/wlroots-0.18";
    const xdg_shell_xml = b.option([]const u8, "xdg-shell-xml", "path to xdg-shell.xml") orelse "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const layer_shell_xml = b.option([]const u8, "layer-shell-xml", "path to wlr-layer-shell XML") orelse "protocols/wlr-layer-shell-unstable-v1.xml";

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

    const gen_layer_shell_client_header = b.addSystemCommand(&.{
        "wayland-scanner",
        "client-header",
        layer_shell_xml,
    });
    const layer_shell_client_header = gen_layer_shell_client_header.addOutputFileArg("wlr-layer-shell-unstable-v1-client-protocol.h");

    const gen_layer_shell_client_code = b.addSystemCommand(&.{
        "wayland-scanner",
        "private-code",
        layer_shell_xml,
    });
    const layer_shell_client_code = gen_layer_shell_client_code.addOutputFileArg("wlr-layer-shell-unstable-v1-protocol.c");

    const apps_catalog_module = b.createModule(.{
        .root_source_file = b.path("src/apps/catalog.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    exe.addIncludePath(.{ .cwd_relative = wlroots_include });
    exe.addIncludePath(xdg_shell_header.dirname());
    exe.addIncludePath(layer_shell_header.dirname());

    exe.linkSystemLibrary(wlroots_lib);
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("cairo");

    b.installArtifact(exe);

    const panel_exe = b.addExecutable(.{
        .name = "axia-panel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/panel/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    panel_exe.linkLibC();
    panel_exe.root_module.addImport("apps_catalog", apps_catalog_module);
    panel_exe.step.dependOn(&gen_xdg_shell_client_header.step);
    panel_exe.step.dependOn(&gen_xdg_shell_client_code.step);
    panel_exe.step.dependOn(&gen_layer_shell_client_header.step);
    panel_exe.step.dependOn(&gen_layer_shell_client_code.step);
    panel_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    panel_exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    panel_exe.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    panel_exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    panel_exe.addIncludePath(xdg_shell_client_header.dirname());
    panel_exe.addIncludePath(layer_shell_client_header.dirname());
    panel_exe.addCSourceFile(.{ .file = xdg_shell_client_code });
    panel_exe.addCSourceFile(.{ .file = layer_shell_client_code });
    panel_exe.linkSystemLibrary("wayland-client");
    panel_exe.linkSystemLibrary("cairo");

    b.installArtifact(panel_exe);

    const dock_exe = b.addExecutable(.{
        .name = "axia-dock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dock/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    dock_exe.linkLibC();
    dock_exe.root_module.addImport("apps_catalog", apps_catalog_module);
    dock_exe.step.dependOn(&gen_xdg_shell_client_header.step);
    dock_exe.step.dependOn(&gen_xdg_shell_client_code.step);
    dock_exe.step.dependOn(&gen_layer_shell_client_header.step);
    dock_exe.step.dependOn(&gen_layer_shell_client_code.step);
    dock_exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
    dock_exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
    dock_exe.addIncludePath(.{ .cwd_relative = "/usr/include/pixman-1" });
    dock_exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    dock_exe.addIncludePath(xdg_shell_client_header.dirname());
    dock_exe.addIncludePath(layer_shell_client_header.dirname());
    dock_exe.addCSourceFile(.{ .file = xdg_shell_client_code });
    dock_exe.addCSourceFile(.{ .file = layer_shell_client_code });
    dock_exe.linkSystemLibrary("wayland-client");
    dock_exe.linkSystemLibrary("cairo");

    b.installArtifact(dock_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Axia-DE");
    run_step.dependOn(&run_cmd.step);

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
}
