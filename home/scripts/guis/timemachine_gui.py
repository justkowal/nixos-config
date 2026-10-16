#!/usr/bin/env python3
"""Time Machine: browse hourly /home snapshots (btrbk or bcachefs), diff and restore files."""

import argparse
import difflib
import os
import shutil
import sys
import threading
from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

APP_ID = "lab.justkowal.TimeMachine"
SNAP_PREFIX = "home."
MAX_SCAN = 20000
MAX_TEXT = 2 * 1024 * 1024

CSS = """
.tm-time { font-feature-settings: "tnum"; }
.tm-status { font-family: monospace; font-weight: bold; min-width: 1.5em; }
.tm-added { color: @success_color; }
.tm-deleted { color: @error_color; }
.tm-modified { color: @warning_color; }
.tm-preview { font-family: monospace; font-size: 10pt; }
"""


def parse_snapshot(name):
    if not name.startswith(SNAP_PREFIX):
        return None
    try:
        return datetime.strptime(name[len(SNAP_PREFIX):], "%Y%m%dT%H%M")
    except ValueError:
        return None


def list_snapshots(snap_dir):
    out = []
    try:
        names = os.listdir(snap_dir)
    except OSError:
        return out
    for name in names:
        ts = parse_snapshot(name)
        if ts:
            out.append((ts, os.path.join(snap_dir, name)))
    out.sort(reverse=True)
    return out


def walk_files(root):
    """Relative path -> (size, mtime) for regular files under root, capped at MAX_SCAN."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
        # nested snapshot dirs show up as empty dirs, skip anyway
        dirnames[:] = [d for d in dirnames if d != ".snapshots"]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            files[os.path.relpath(full, root)] = (st.st_size, st.st_mtime_ns)
            if len(files) >= MAX_SCAN:
                return files, True
    return files, False


def compare(snap_root, live_root):
    old, trunc_a = walk_files(snap_root)
    new, trunc_b = walk_files(live_root)
    changes = []
    for rel, meta in old.items():
        if rel not in new:
            changes.append(("D", rel))
        elif new[rel] != meta:
            changes.append(("M", rel))
    for rel in new.keys() - old.keys():
        changes.append(("A", rel))
    changes.sort(key=lambda c: c[1])
    return changes, trunc_a or trunc_b


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_TEXT:
            return None
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return ""
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def restore_target(path):
    if not os.path.exists(path):
        return path
    candidate = path + ".restored"
    n = 1
    while os.path.exists(candidate):
        n += 1
        candidate = f"{path}.restored.{n}"
    return candidate


def humanize(ts):
    delta = datetime.now() - ts
    hours = int(delta.total_seconds() // 3600)
    if hours < 1:
        return "less than an hour ago"
    if hours < 48:
        return f"{hours} h ago"
    return f"{hours // 24} days ago"


class Window(Adw.ApplicationWindow):
    def __init__(self, app, snap_dir, source, folder):
        super().__init__(application=app, title="Time Machine")
        self.set_default_size(1200, 760)
        self.snap_dir = snap_dir
        self.source = os.path.realpath(source)
        self.folder = None
        self.snapshot = None
        self.selected = None
        self.generation = 0

        header = Adw.HeaderBar()
        self.title = Adw.WindowTitle(title="Time Machine", subtitle="")
        header.set_title_widget(self.title)
        pick = Gtk.Button(icon_name="folder-open-symbolic", tooltip_text="Choose folder")
        pick.connect("clicked", self.on_pick)
        header.pack_start(pick)
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Rescan")
        refresh.connect("clicked", lambda *_: self.load_snapshots())
        header.pack_end(refresh)

        self.snap_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.snap_list.add_css_class("navigation-sidebar")
        self.snap_list.connect("row-selected", self.on_snapshot_selected)

        self.file_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.file_list.add_css_class("navigation-sidebar")
        self.file_list.connect("row-selected", self.on_file_selected)
        self.file_status = Gtk.Label(xalign=0, margin_start=12, margin_end=12, margin_top=6,
                                     margin_bottom=6, wrap=True)
        self.file_status.add_css_class("dim-label")
        self.spinner = Gtk.Spinner()

        self.preview = Gtk.TextView(editable=False, monospace=True, cursor_visible=False,
                                    left_margin=12, right_margin=12, top_margin=12)
        self.preview.add_css_class("tm-preview")
        buf = self.preview.get_buffer()
        buf.create_tag("add", foreground="#2ec27e")
        buf.create_tag("del", foreground="#e01b24")
        buf.create_tag("hunk", foreground="#3584e4", weight=Pango.Weight.BOLD)

        self.restore_btn = Gtk.Button(label="Restore", sensitive=False)
        self.restore_btn.add_css_class("suggested-action")
        self.restore_btn.connect("clicked", self.on_restore)
        self.preview_label = Gtk.Label(xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.START)
        self.preview_label.add_css_class("heading")

        self.toasts = Adw.ToastOverlay()

        snaps_col = self.column("Snapshots", self.snap_list)
        files_head = Gtk.Box(spacing=8)
        files_head.append(Gtk.Label(label="Changed since", xalign=0, hexpand=True,
                                    css_classes=["heading"]))
        files_head.append(self.spinner)
        files_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        files_head.set_margin_start(12)
        files_head.set_margin_end(12)
        files_head.set_margin_top(10)
        files_box.append(files_head)
        files_box.append(self.file_status)
        files_box.append(Gtk.ScrolledWindow(child=self.file_list, vexpand=True))

        prev_head = Gtk.Box(spacing=8, margin_start=12, margin_end=12, margin_top=8, margin_bottom=8)
        prev_head.append(self.preview_label)
        prev_head.append(self.restore_btn)
        prev_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        prev_box.append(prev_head)
        prev_box.append(Gtk.Separator())
        prev_box.append(Gtk.ScrolledWindow(child=self.preview, vexpand=True, hexpand=True))

        inner = Gtk.Paned(start_child=files_box, end_child=prev_box, position=360,
                          shrink_start_child=False)
        outer = Gtk.Paned(start_child=snaps_col, end_child=inner, position=240,
                          shrink_start_child=False)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(outer)
        self.toasts.set_child(view)
        self.set_content(self.toasts)

        self.set_folder(folder or self.source)

    def column(self, title, child):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(Gtk.Label(label=title, xalign=0, css_classes=["heading"], margin_start=12,
                             margin_top=10, margin_bottom=6))
        box.append(Gtk.ScrolledWindow(child=child, vexpand=True))
        return box

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text, timeout=4))

    # paths

    def rel_folder(self):
        return os.path.relpath(self.folder, self.source)

    def snap_path(self, rel_file=""):
        return os.path.normpath(os.path.join(self.snapshot, self.rel_folder(), rel_file))

    def live_path(self, rel_file=""):
        return os.path.normpath(os.path.join(self.folder, rel_file))

    def set_folder(self, folder):
        folder = os.path.realpath(folder)
        if os.path.commonpath([folder, self.source]) != self.source:
            self.toast(f"Only folders under {self.source} are snapshotted")
            return
        self.folder = folder
        self.title.set_subtitle(folder)
        self.load_snapshots()

    def on_pick(self, _btn):
        dialog = Gtk.FileDialog(title="Choose a folder")
        if self.folder:
            dialog.set_initial_folder(Gio.File.new_for_path(self.folder))
        dialog.select_folder(self, None, self.on_picked)

    def on_picked(self, dialog, result):
        try:
            f = dialog.select_folder_finish(result)
        except GLib.Error:
            return
        if f and f.get_path():
            self.set_folder(f.get_path())

    # snapshots

    def load_snapshots(self):
        self.generation += 1
        gen = self.generation
        self.spinner.start()
        threading.Thread(target=lambda: GLib.idle_add(self.show_snapshots, gen,
                                                      list_snapshots(self.snap_dir)),
                         daemon=True).start()

    def show_snapshots(self, gen, snaps):
        if gen != self.generation:
            return False
        self.spinner.stop()
        self.snap_list.remove_all()
        if not snaps:
            self.file_status.set_label(f"No snapshots found in {self.snap_dir}")
        for ts, path in snaps:
            row = Gtk.ListBoxRow()
            row.path = path
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin_top=4, margin_bottom=4)
            label = Gtk.Label(label=ts.strftime("%a %d %b  %H:%M"), xalign=0)
            label.add_css_class("tm-time")
            sub = Gtk.Label(label=humanize(ts), xalign=0, css_classes=["dim-label", "caption"])
            box.append(label)
            box.append(sub)
            row.set_child(box)
            self.snap_list.append(row)
        first = self.snap_list.get_row_at_index(0)
        if first:
            self.snap_list.select_row(first)
        return False

    def on_snapshot_selected(self, _list, row):
        if row is None:
            return
        self.snapshot = row.path
        self.scan()

    # files

    def scan(self):
        self.generation += 1
        gen = self.generation
        snap_root, live_root = self.snap_path(), self.live_path()
        self.file_list.remove_all()
        self.clear_preview()
        self.file_status.set_label("Scanning")
        self.spinner.start()

        def work():
            if not os.path.isdir(snap_root):
                result = ([], False, "Folder did not exist in this snapshot")
            else:
                changes, truncated = compare(snap_root, live_root)
                result = (changes, truncated, None)
            GLib.idle_add(self.show_changes, gen, *result)

        threading.Thread(target=work, daemon=True).start()

    def show_changes(self, gen, changes, truncated, error):
        if gen != self.generation:
            return False
        self.spinner.stop()
        if error:
            self.file_status.set_label(error)
            return False
        note = f"{len(changes)} changed files"
        if truncated:
            note += f" (scan stopped at {MAX_SCAN} files, pick a smaller folder)"
        self.file_status.set_label(note if changes else "No differences")
        kinds = {"A": ("tm-added", "Added since"), "D": ("tm-deleted", "Deleted since"),
                 "M": ("tm-modified", "Modified since")}
        for status, rel in changes:
            row = Gtk.ListBoxRow()
            row.change = (status, rel)
            box = Gtk.Box(spacing=8, margin_top=3, margin_bottom=3)
            css, tip = kinds[status]
            mark = Gtk.Label(label=status, tooltip_text=tip, css_classes=["tm-status", css])
            name = Gtk.Label(label=rel, xalign=0, hexpand=True,
                             ellipsize=Pango.EllipsizeMode.START)
            box.append(mark)
            box.append(name)
            row.set_child(box)
            self.file_list.append(row)
        return False

    def clear_preview(self):
        self.selected = None
        self.preview.get_buffer().set_text("")
        self.preview_label.set_label("")
        self.restore_btn.set_sensitive(False)

    def on_file_selected(self, _list, row):
        if row is None:
            return
        status, rel = row.change
        self.selected = (status, rel)
        self.preview_label.set_label(rel)
        self.restore_btn.set_sensitive(status != "A")
        gen = self.generation
        old_p, new_p = self.snap_path(rel), self.live_path(rel)

        def work():
            old = read_text(old_p) if status != "A" else ""
            new = read_text(new_p) if status != "D" else ""
            if old is None or new is None:
                lines = [("Binary or large file, no preview.\n", None)]
            elif status == "D":
                lines = [(line, None) for line in old.splitlines(keepends=True)]
            else:
                diff = difflib.unified_diff(old.splitlines(keepends=True),
                                            new.splitlines(keepends=True),
                                            "snapshot", "now", n=3)
                lines = []
                for line in diff:
                    tag = None
                    if line.startswith("@@"):
                        tag = "hunk"
                    elif line.startswith("+") and not line.startswith("+++"):
                        tag = "add"
                    elif line.startswith("-") and not line.startswith("---"):
                        tag = "del"
                    lines.append((line if line.endswith("\n") else line + "\n", tag))
                if not lines:
                    lines = [("Only metadata changed (size or mtime).\n", None)]
            GLib.idle_add(self.show_preview, gen, rel, lines)

        threading.Thread(target=work, daemon=True).start()

    def show_preview(self, gen, rel, lines):
        if gen != self.generation or not self.selected or self.selected[1] != rel:
            return False
        buf = self.preview.get_buffer()
        buf.set_text("")
        for text, tag in lines:
            end = buf.get_end_iter()
            if tag:
                buf.insert_with_tags_by_name(end, text, tag)
            else:
                buf.insert(end, text)
        return False

    def on_restore(self, _btn):
        if not self.selected:
            return
        _status, rel = self.selected
        src, dst = self.snap_path(rel), self.live_path(rel)
        target = restore_target(dst)
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(src, target)
        except OSError as e:
            self.toast(f"Restore failed: {e.strerror}")
            return
        self.toast(f"Restored to {os.path.basename(target)}")
        self.scan()


class App(Adw.Application):
    def __init__(self, args):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.args = args

    def do_activate(self):
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        Window(self, self.args.snapshots, self.args.source, self.args.folder).present()


def main():
    parser = argparse.ArgumentParser(description="Browse and restore files from /home snapshots")
    parser.add_argument("folder", nargs="?", help="folder to open (default: home)")
    parser.add_argument("--snapshots", default=os.environ.get("TIMEMACHINE_SNAPSHOTS",
                                                             "/home/.snapshots"))
    parser.add_argument("--source", default="/home", help="live path the snapshots were taken of")
    args = parser.parse_args()
    if args.folder is None:
        args.folder = os.path.expanduser("~")
    return App(args).run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
