//! System tray for the bar: the StatusNotifier watcher and host, written on GIO's D-Bus API.
//! Clicks go to the item's own Activate and ContextMenu methods, so apps that draw their own menu
//! work; apps that only expose a dbusmenu object do not get a menu from this bar yet.
//! If something else (Waybar) already owns the watcher name, the tray stays empty and nothing breaks.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gtk::{gdk, gio, glib, prelude::*};
use gtk4 as gtk;

const WATCHER: &str = "org.kde.StatusNotifierWatcher";
const ITEM_IFACE: &str = "org.kde.StatusNotifierItem";
const XML: &str = r#"<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" name="service" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" name="service" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
  </interface>
</node>"#;

/// `service` as apps send it: a bus name, a bus name plus path, or just a path (then the sender is the name).
pub fn split_service(service: &str, sender: Option<&str>) -> Option<(String, String)> {
    if let Some(path) = service.strip_prefix('/') {
        return sender.map(|s| (s.to_owned(), format!("/{path}")));
    }
    match service.split_once('/') {
        Some((name, path)) => Some((name.to_owned(), format!("/{path}"))),
        None if service.is_empty() => None,
        None => Some((service.to_owned(), "/StatusNotifierItem".to_owned())),
    }
}

/// ARGB32 bytes in network order are gdk's A8r8g8b8; the biggest icon in the list wins.
fn pixmap_texture(pixmaps: &glib::Variant) -> Option<gdk::Texture> {
    let best = (0..pixmaps.n_children())
        .map(|i| pixmaps.child_value(i))
        .max_by_key(|p| p.child_value(0).get::<i32>().unwrap_or(0))?;
    let (w, h) = (
        best.child_value(0).get::<i32>()?,
        best.child_value(1).get::<i32>()?,
    );
    let data: Vec<u8> = best.child_value(2).fixed_array::<u8>().ok()?.to_vec();
    (w > 0 && h > 0 && data.len() == (w * h * 4) as usize).then(|| {
        gdk::MemoryTexture::new(
            w,
            h,
            gdk::MemoryFormat::A8r8g8b8,
            &glib::Bytes::from_owned(data),
            (w * 4) as usize,
        )
        .upcast()
    })
}

struct Item {
    button: gtk::Button,
    image: gtk::Image,
    /// unsubscribes when the item goes away
    _sub: Option<gio::SignalSubscription>,
}

type Items = Rc<RefCell<HashMap<String, Item>>>;

fn call(conn: &gio::DBusConnection, name: &str, path: &str, method: &str) {
    conn.call(
        Some(name),
        path,
        ITEM_IFACE,
        method,
        Some(&(0i32, 0i32).to_variant()),
        None,
        gio::DBusCallFlags::NONE,
        -1,
        gio::Cancellable::NONE,
        |_| {},
    );
}

async fn refresh(conn: &gio::DBusConnection, name: &str, path: &str, item: &Item) {
    let args = (ITEM_IFACE,).to_variant();
    let Ok(reply) = conn
        .call_future(
            Some(name),
            path,
            "org.freedesktop.DBus.Properties",
            "GetAll",
            Some(&args),
            None,
            gio::DBusCallFlags::NONE,
            2000,
        )
        .await
    else {
        eprintln!("labd: tray item {name}{path} did not answer GetAll");
        return;
    };
    let props = glib::VariantDict::new(Some(&reply.child_value(0)));
    let text = |k: &str| props.lookup::<String>(k).ok().flatten().unwrap_or_default();
    item.button.set_visible(text("Status") != "Passive");
    let tip = text("Title");
    item.button
        .set_tooltip_text((!tip.is_empty()).then_some(tip.as_str()));
    let theme_path = text("IconThemePath");
    if !theme_path.is_empty() {
        if let Some(d) = gdk::Display::default() {
            gtk::IconTheme::for_display(&d).add_search_path(theme_path);
        }
    }
    let icon = text("IconName");
    if !icon.is_empty() {
        item.image.set_icon_name(Some(&icon));
    } else if let Some(tex) = props
        .lookup_value("IconPixmap", None)
        .and_then(|p| pixmap_texture(&p))
    {
        item.image.set_paintable(Some(&tex));
    } else {
        item.image.set_icon_name(Some("image-missing"));
    }
}

fn add(conn: &gio::DBusConnection, items: &Items, row: &gtk::Box, name: String, path: String) {
    let key = format!("{name}{path}");
    if items.borrow().contains_key(&key) {
        return;
    }
    let image = gtk::Image::builder().pixel_size(16).build();
    let button = gtk::Button::builder().child(&image).build();
    button.add_css_class("flat");
    button.add_css_class("tray-item");
    for (b, method) in [
        (1u32, "Activate"),
        (2, "SecondaryActivate"),
        (3, "ContextMenu"),
    ] {
        let g = gtk::GestureClick::builder().button(b).build();
        let (conn, name, path) = (conn.clone(), name.clone(), path.clone());
        g.connect_released(move |_, _, _, _| call(&conn, &name, &path, method));
        button.add_controller(g);
    }
    row.append(&button);
    row.set_visible(true);
    // every New* signal from the item means something changed, so read it all again
    let sub = {
        let (conn2, name2, path2) = (conn.clone(), name.clone(), path.clone());
        let (button, image) = (button.clone(), image.clone());
        conn.subscribe_to_signal(
            Some(&name),
            Some(ITEM_IFACE),
            None,
            Some(&path),
            None,
            gio::DBusSignalFlags::NONE,
            move |_| {
                let (conn, name, path) = (conn2.clone(), name2.clone(), path2.clone());
                let item = Item {
                    button: button.clone(),
                    image: image.clone(),
                    _sub: None,
                };
                glib::spawn_future_local(async move {
                    refresh(&conn, &name, &path, &item).await;
                });
            },
        )
    };
    let item = Item {
        button,
        image,
        _sub: Some(sub),
    };
    {
        let (conn, name, path) = (conn.clone(), name.clone(), path.clone());
        let probe = Item {
            button: item.button.clone(),
            image: item.image.clone(),
            _sub: None,
        };
        glib::spawn_future_local(async move {
            refresh(&conn, &name, &path, &probe).await;
        });
    }
    items.borrow_mut().insert(key.clone(), item);

    // gone when its bus name goes away
    let (items, row, conn2) = (items.clone(), row.clone(), conn.clone());
    gio::bus_watch_name(
        gio::BusType::Session,
        &name,
        gio::BusNameWatcherFlags::NONE,
        |_, _, _| {},
        move |_, _| {
            if std::env::var_os("LABD_DEBUG").is_some() {
                eprintln!("labd: tray name vanished {key}");
            }
            if let Some(item) = items.borrow_mut().remove(&key) {
                row.remove(&item.button);
            }
            row.set_visible(row.first_child().is_some());
            let _ = conn2.emit_signal(
                None,
                "/StatusNotifierWatcher",
                WATCHER,
                "StatusNotifierItemUnregistered",
                Some(&(key.clone(),).to_variant()),
            );
        },
    );
}

pub fn widget() -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(2)
        .build();
    row.add_css_class("tray");
    row.set_visible(false);
    let items: Items = Rc::new(RefCell::new(HashMap::new()));
    let Some(info) = gio::DBusNodeInfo::for_xml(XML)
        .ok()
        .and_then(|n| n.lookup_interface(WATCHER))
    else {
        return row.upcast();
    };
    let (acq_items, acq_row) = (items.clone(), row.clone());
    let owner = gio::bus_own_name(
        gio::BusType::Session,
        WATCHER,
        gio::BusNameOwnerFlags::NONE,
        move |conn, _| {
            let (items, row, conn_c) = (acq_items.clone(), acq_row.clone(), conn.clone());
            let get_items = acq_items.clone();
            let _ = conn
                .register_object("/StatusNotifierWatcher", &info)
                .method_call(
                    move |conn, sender, _path, _iface, method, params, invocation| {
                        let service = params.child_value(0).get::<String>().unwrap_or_default();
                        if method == "RegisterStatusNotifierItem" {
                            if let Some((name, path)) = split_service(&service, sender) {
                                add(&conn_c, &items, &row, name.clone(), path.clone());
                                let _ = conn.emit_signal(
                                    None,
                                    "/StatusNotifierWatcher",
                                    WATCHER,
                                    "StatusNotifierItemRegistered",
                                    Some(&(format!("{name}{path}"),).to_variant()),
                                );
                            }
                        }
                        invocation.return_value(None);
                    },
                )
                .property(move |_, _, _, _, prop| match prop {
                    "RegisteredStatusNotifierItems" => get_items
                        .borrow()
                        .keys()
                        .cloned()
                        .collect::<Vec<_>>()
                        .to_variant(),
                    "IsStatusNotifierHostRegistered" => true.to_variant(),
                    _ => 0i32.to_variant(),
                })
                .build();
        },
        |conn, _| {
            let _ = conn.emit_signal(
                None,
                "/StatusNotifierWatcher",
                WATCHER,
                "StatusNotifierHostRegistered",
                None,
            );
        },
        |_, _| {
            eprintln!("labd: another process owns the tray watcher, the Lab bar tray stays empty")
        },
    );
    // alive for the whole run
    std::mem::forget(owner);
    row.upcast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn services_split_into_name_and_path() {
        assert_eq!(
            split_service(":1.42", None),
            Some((":1.42".into(), "/StatusNotifierItem".into()))
        );
        assert_eq!(
            split_service("org.app.Item/Custom/Path", None),
            Some(("org.app.Item".into(), "/Custom/Path".into()))
        );
        assert_eq!(
            split_service("/org/ayatana/Item", Some(":1.7")),
            Some((":1.7".into(), "/org/ayatana/Item".into()))
        );
        assert_eq!(split_service("/org/x", None), None);
        assert_eq!(split_service("", None), None);
    }
}
