/* Pointer lock and relative motion for lab-peek. GTK4 has no API for either, so this binds the two Wayland
 * protocols on GTK's own connection and hands the deltas to Python. Everything runs on the main thread,
 * GTK dispatches the events. */
#include <stdint.h>
#include <string.h>
#include <wayland-client.h>
#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"

typedef void (*motion_cb)(double dx, double dy);

static struct wl_display *dpy;
static struct wl_registry *reg;
static struct zwp_pointer_constraints_v1 *constraints;
static struct zwp_relative_pointer_manager_v1 *relman;
static struct zwp_locked_pointer_v1 *lock;
static struct zwp_relative_pointer_v1 *rel;
static motion_cb cb;
static int locked;

static void on_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
	(void)d;
	(void)ver;
	if (!strcmp(iface, zwp_pointer_constraints_v1_interface.name))
		constraints = wl_registry_bind(r, name, &zwp_pointer_constraints_v1_interface, 1);
	else if (!strcmp(iface, zwp_relative_pointer_manager_v1_interface.name))
		relman = wl_registry_bind(r, name, &zwp_relative_pointer_manager_v1_interface, 1);
}

static void on_global_remove(void *d, struct wl_registry *r, uint32_t name)
{
	(void)d;
	(void)r;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {on_global, on_global_remove};

static void on_locked(void *d, struct zwp_locked_pointer_v1 *l)
{
	(void)d;
	(void)l;
	locked = 1;
}

static void on_unlocked(void *d, struct zwp_locked_pointer_v1 *l)
{
	(void)d;
	(void)l;
	locked = 0;
}

static const struct zwp_locked_pointer_v1_listener lock_listener = {on_locked, on_unlocked};

static void on_relative(void *d, struct zwp_relative_pointer_v1 *r, uint32_t hi, uint32_t lo, wl_fixed_t dx,
			wl_fixed_t dy, wl_fixed_t dxu, wl_fixed_t dyu)
{
	(void)d;
	(void)r;
	(void)hi;
	(void)lo;
	(void)dx;
	(void)dy;
	if (cb)
		cb(wl_fixed_to_double(dxu), wl_fixed_to_double(dyu));
}

static const struct zwp_relative_pointer_v1_listener relative_listener = {on_relative};

void lab_lock_init(struct wl_display *display)
{
	if (reg)
		return;
	dpy = display;
	reg = wl_display_get_registry(display);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_flush(display);
}

int lab_lock_ready(void)
{
	return constraints && relman;
}

int lab_lock_active(void)
{
	return locked;
}

int lab_lock_enable(struct wl_surface *surface, struct wl_pointer *pointer, motion_cb callback)
{
	if (!lab_lock_ready() || lock)
		return 0;
	cb = callback;
	lock = zwp_pointer_constraints_v1_lock_pointer(constraints, surface, pointer, NULL,
						      ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT);
	zwp_locked_pointer_v1_add_listener(lock, &lock_listener, NULL);
	rel = zwp_relative_pointer_manager_v1_get_relative_pointer(relman, pointer);
	zwp_relative_pointer_v1_add_listener(rel, &relative_listener, NULL);
	wl_display_flush(dpy);
	return 1;
}

void lab_lock_disable(void)
{
	if (lock)
		zwp_locked_pointer_v1_destroy(lock);
	if (rel)
		zwp_relative_pointer_v1_destroy(rel);
	lock = NULL;
	rel = NULL;
	locked = 0;
	cb = NULL;
	if (dpy)
		wl_display_flush(dpy);
}
