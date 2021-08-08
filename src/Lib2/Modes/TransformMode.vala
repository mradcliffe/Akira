/**
 * Copyright (c) 2021 Alecaddd (https://alecaddd.com)
 *
 * This file is part of Akira.
 *
 * Akira is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * Akira is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with Akira. If not, see <https://www.gnu.org/licenses/>.
 *
 * Authored by: Martin "mbfraga" Fraga <mbfraga@gmail.com>
 */

/*
 * TransformMode handles mouse-activated transformations. Static methods can
 * be used to apply the underlying code on top of other modes that may need to
 * use the functionality.
 */
public class Akira.Lib2.Modes.TransformMode : AbstractInteractionMode {
    private const double ROTATION_FIXED_STEP = 15.0;

    public unowned Lib2.ViewCanvas view_canvas { get; construct; }

    public Utils.Nobs.Nob nob = Utils.Nobs.Nob.NONE;

    public class DragItemData : Object {
        public Lib2.Components.CompiledGeometry item_geometry;
    }

    public class InitialDragState : Object {
        public double press_x;
        public double press_y;

        // initial_selection_data
        public Geometry.Quad area;

        public Gee.HashMap<int, DragItemData> item_data_map;

        construct {
            item_data_map = new Gee.HashMap<int, DragItemData> ();
        }
    }

    public class TransformExtraContext : Object {
        public Lib2.Managers.SnapManager.SnapGuideData snap_guide_data;
    }

    private Lib2.Items.NodeSelection selection;
    private InitialDragState initial_drag_state;
    public TransformExtraContext transform_extra_context;


    public TransformMode (Akira.Lib2.ViewCanvas canvas, Utils.Nobs.Nob selected_nob) {
        Object (view_canvas: canvas);
        nob = selected_nob;
        initial_drag_state = new InitialDragState ();
    }

    construct {
        transform_extra_context = new TransformExtraContext ();
        transform_extra_context.snap_guide_data = new Lib2.Managers.SnapManager.SnapGuideData ();
    }

    public override void mode_begin () {
        if (view_canvas.selection_manager.selection.is_empty ()) {
            request_deregistration (mode_type ());
            return;
        }

        selection = view_canvas.selection_manager.selection;
        initial_drag_state.area = selection.coordinates ();

        foreach (var node in selection.nodes.values) {
            collect_geometries (node.node, ref initial_drag_state);
        }
    }

    private static void collect_geometries (Lib2.Items.ModelNode subtree, ref InitialDragState state) {
        if (state.item_data_map.has_key (subtree.id)) {
            return;
        }

        var data = new DragItemData ();
        data.item_geometry = subtree.instance.compiled_geometry.copy ();
        state.item_data_map[subtree.id] = data;

        if (subtree.children == null || subtree.children.length == 0) {
            return;
        }

        foreach (unowned var child in subtree.children.data) {
            collect_geometries (child, ref state);
        }
    }

    public override void mode_end () {
        transform_extra_context = null;
        view_canvas.window.event_bus.update_snap_decorators ();
    }

    public override AbstractInteractionMode.ModeType mode_type () {
        return AbstractInteractionMode.ModeType.TRANSFORM;
    }

    public override Utils.Nobs.Nob acitve_nob () {
        return nob;
    }

    public override Gdk.CursorType? cursor_type () {
        return Utils.Nobs.cursor_from_nob (nob);
    }

    public override bool key_press_event (Gdk.EventKey event) {
        return true;
    }

    public override bool key_release_event (Gdk.EventKey event) {
        return false;
    }

    public override bool button_press_event (Gdk.EventButton event) {
        initial_drag_state.press_x = event.x;
        initial_drag_state.press_y = event.y;
        return true;
    }

    public override bool button_release_event (Gdk.EventButton event) {
        request_deregistration (mode_type ());
        return true;
    }

    public override bool motion_notify_event (Gdk.EventMotion event) {
        switch (nob) {
            case Utils.Nobs.Nob.NONE:
                move_from_event (
                    view_canvas,
                    selection,
                    initial_drag_state,
                    event.x,
                    event.y,
                    ref transform_extra_context.snap_guide_data
                );
                break;
            case Utils.Nobs.Nob.ROTATE:
                rotate_from_event (
                    view_canvas,
                    selection,
                    initial_drag_state,
                    event.x,
                    event.y
                );
                break;
            default:
                scale_from_event (
                    view_canvas,
                    selection,
                    initial_drag_state,
                    nob,
                    event.x,
                    event.y
                );
                break;
        }

        return true;
    }

    public override Object? extra_context () {
        return transform_extra_context;
    }

    public static void move_from_event (
        ViewCanvas view_canvas,
        Lib2.Items.NodeSelection selection,
        InitialDragState initial_drag_state,
        double event_x,
        double event_y,
        ref Lib2.Managers.SnapManager.SnapGuideData guide_data
    ) {
        var blocker = new Lib2.Managers.SelectionManager.ChangeSignalBlocker (view_canvas.selection_manager);
        (void) blocker;

        var delta_x = event_x - initial_drag_state.press_x;
        var delta_y = event_y - initial_drag_state.press_y;

        double top = 0.0;
        double left = 0.0;
        double bottom = 0.0;
        double right = 0.0;
        initial_drag_state.area.top_bottom (ref top, ref bottom);
        initial_drag_state.area.left_right (ref left, ref right);

        Utils.AffineTransform.add_grid_snap_delta (top, left, ref delta_x, ref delta_y);

        int snap_offset_x = 0;
        int snap_offset_y = 0;

        if (settings.enable_snaps) {
            guide_data.type = Akira.Lib2.Managers.SnapManager.SnapGuideType.NONE;
            var sensitivity = Utils.Snapping2.adjusted_sensitivity (view_canvas.current_scale);
            var selection_area = Geometry.Rectangle () {
                    left = left + delta_x,
                    top = top + delta_y,
                    right = right + delta_x,
                    bottom = bottom + delta_y
            };

            var snap_grid = Utils.Snapping2.generate_best_snap_grid (
                view_canvas,
                selection,
                selection_area,
                sensitivity
            );

            if (!snap_grid.is_empty ()) {
                var matches = Utils.Snapping2.generate_snap_matches (
                    snap_grid,
                    selection,
                    selection_area,
                    sensitivity
                );


                if (matches.h_data.snap_found ()) {
                    snap_offset_x = matches.h_data.snap_offset ();
                    guide_data.type = Akira.Lib2.Managers.SnapManager.SnapGuideType.SELECTION;
                }

                if (matches.v_data.snap_found ()) {
                    snap_offset_y = matches.v_data.snap_offset ();
                    guide_data.type = Akira.Lib2.Managers.SnapManager.SnapGuideType.SELECTION;
                }
            }
        }

        foreach (var sel_node in selection.nodes.values) {
            unowned var item = sel_node.node.instance;

            if (item.is_group) {
                translate_group (
                    view_canvas,
                    sel_node.node,
                    initial_drag_state,
                    delta_x, delta_y,
                    snap_offset_x,
                    snap_offset_y
                );

                if (item.components.center == null) {
                    continue;
                }
            }

            var item_drag_data = initial_drag_state.item_data_map[sel_node.node.id];
            var new_center_x = item_drag_data.item_geometry.area.center_x + delta_x + snap_offset_x;
            var new_center_y = item_drag_data.item_geometry.area.center_y + delta_y + snap_offset_y;
            item.components.center = new Lib2.Components.Coordinates (new_center_x, new_center_y);
            item.mark_geometry_dirty ();
        }

        view_canvas.items_manager.compile_model ();
        view_canvas.window.event_bus.update_snap_decorators ();
    }

    private static void translate_group (
        ViewCanvas view_canvas,
        Lib2.Items.ModelNode group,
        InitialDragState initial_drag_state,
        double delta_x,
        double delta_y,
        double snap_offset_x,
        double snap_offset_y
    ) {
        if (group.children == null) {
            return;
        }

        foreach (unowned var child in group.children.data) {
            if (child.instance.is_group) {
                translate_group (
                    view_canvas,
                    group,
                    initial_drag_state,
                    delta_x,
                    delta_y,
                    snap_offset_x,
                    snap_offset_y
                );
                continue;
            }

            unowned var item = child.instance;
            var item_drag_data = initial_drag_state.item_data_map[child.id];
            var new_center_x = item_drag_data.item_geometry.area.center_x + delta_x + snap_offset_x;
            var new_center_y = item_drag_data.item_geometry.area.center_y + delta_y + snap_offset_y;
            item.components.center = new Lib2.Components.Coordinates (new_center_x, new_center_y);
            item.mark_geometry_dirty (true);
        }
    }

    public static void scale_from_event (
        ViewCanvas view_canvas,
        Lib2.Items.NodeSelection selection,
        InitialDragState initial_drag_state,
        Utils.Nobs.Nob nob,
        double event_x,
        double event_y
    ) {
        // TODO WIP
        var blocker = new Lib2.Managers.SelectionManager.ChangeSignalBlocker (view_canvas.selection_manager);
        (void) blocker;

        double rot_center_x = initial_drag_state.area.center_x;
        double rot_center_y = initial_drag_state.area.center_y;

        var itr = initial_drag_state.area.transformation;
        itr.invert ();

        var local_area = initial_drag_state.area;
        Utils.GeometryMath.transform_quad (itr, ref local_area);

        var adjusted_event_x = event_x - rot_center_x;
        var adjusted_event_y = event_y - rot_center_y;
        itr.transform_distance (ref adjusted_event_x, ref adjusted_event_y);
        adjusted_event_x += rot_center_x;
        adjusted_event_y += rot_center_y;

        var start_width = double.max (1.0, local_area.width);
        var start_height = double.max (1.0, local_area.height);

        double nob_x = 0.0;
        double nob_y = 0.0;

        Utils.Nobs.nob_xy_from_coordinates (
            nob,
            local_area,
            1.0,
            ref nob_x,
            ref nob_y
        );

        double inc_width = 0;
        double inc_height = 0;
        double inc_x = 0;
        double inc_y = 0;

        var tr = Cairo.Matrix.identity ();
        Utils.AffineTransform.calculate_size_adjustments2 (
            nob,
            start_width,
            start_height,
            adjusted_event_x - nob_x,
            adjusted_event_y - nob_y,
            start_width / start_height,
            view_canvas.ctrl_is_pressed,
            view_canvas.shift_is_pressed,
            tr,
            ref inc_x,
            ref inc_y,
            ref inc_width,
            ref inc_height
        );

        double size_off_x = inc_width / 2.0;
        double size_off_y = inc_height / 2.0;
        tr.transform_distance (ref size_off_x, ref size_off_y);

        var local_offset_x = inc_x + size_off_x;
        var local_offset_y = inc_y + size_off_y;

        var new_area = Geometry.Quad.from_components (
            rot_center_x + local_offset_x,
            rot_center_y + local_offset_y,
            start_width + inc_width,
            start_height + inc_height,
            tr
        );

        var global_offset_x = local_offset_x;
        var global_offset_y = local_offset_y;
        initial_drag_state.area.transformation.transform_distance (ref global_offset_x, ref global_offset_y);

        var local_sx = new_area.bounding_box.width / local_area.bounding_box.width;
        var local_sy = new_area.bounding_box.height / local_area.bounding_box.height;

        foreach (var node in selection.nodes.values) {
            scale_node (
                view_canvas,
                node.node,
                initial_drag_state,
                itr,
                global_offset_x,
                global_offset_y,
                local_sx,
                local_sy
            );
        }

        view_canvas.items_manager.compile_model ();
    }

    /*
     * Scales a node and its children relative to a reference frame.
     */
    public static void scale_node (
        ViewCanvas view_canvas,
        Lib2.Items.ModelNode node,
        InitialDragState initial_drag_state,
        Cairo.Matrix inverse_reference_matrix,
        double global_offset_x,
        double global_offset_y,
        double reference_sx,
        double reference_sy
    ) {
        // #TODO wip
        unowned var item = node.instance;
        if (item.components.center != null && item.components.size != null) {
            var item_drag_data = initial_drag_state.item_data_map[node.id];

            var strf = Cairo.Matrix (reference_sx, 0, 0, reference_sy, 0, 0);
            double center_offset_x = item_drag_data.item_geometry.area.center_x - initial_drag_state.area.center_x;
            double center_offset_y = item_drag_data.item_geometry.area.center_y - initial_drag_state.area.center_y;

            var new_transform = Utils.GeometryMath.multiply_matrices (
                item_drag_data.item_geometry.transformation_matrix,
                inverse_reference_matrix
            );

            new_transform = Utils.GeometryMath.multiply_matrices (new_transform, strf);
            new_transform = Utils.GeometryMath.multiply_matrices (
                new_transform,
                initial_drag_state.area.transformation
            );

            var new_width = item_drag_data.item_geometry.source_width;
            var new_height = item_drag_data.item_geometry.source_height;
            double scale_x = 0.0;
            double scale_y = 0.0;
            double shear_x = 0.0;
            double angle = 0.0;

            Utils.GeometryMath.decompose_matrix (new_transform, ref scale_x, ref scale_y, ref shear_x, ref angle);

            var scale_transform = Cairo.Matrix (scale_x, 0, 0, scale_y, 0, 0);
            scale_transform.transform_distance (ref new_width, ref new_height);

            strf.transform_distance (ref center_offset_x, ref center_offset_y);
            var d_x = initial_drag_state.area.center_x + global_offset_x + center_offset_x;
            var d_y = initial_drag_state.area.center_y + global_offset_y + center_offset_y;

            item.components.center = new Lib2.Components.Coordinates (d_x, d_y);
            item.components.transform = new Lib2.Components.Transform (angle, 1.0, 1.0, shear_x, 0);
            item.components.size = new Lib2.Components.Size (new_width, new_height, false);

            item.mark_geometry_dirty ();
        }


        unowned var layout = item.components.layout;
        if ((layout == null || layout.dilated_resize) && node.children != null) {
            foreach (unowned var child in node.children.data) {
                scale_node (
                    view_canvas,
                    child,
                    initial_drag_state,
                    inverse_reference_matrix,
                    global_offset_x,
                    global_offset_y,
                    reference_sx,
                    reference_sy
                );
            }
        }
    }

    public static void rotate_from_event (
        ViewCanvas view_canvas,
        Lib2.Items.NodeSelection selection,
        InitialDragState initial_drag_state,
        double event_x,
        double event_y
    ) {
        var blocker = new Lib2.Managers.SelectionManager.ChangeSignalBlocker (view_canvas.selection_manager);
        (void) blocker;

        double original_center_x = initial_drag_state.area.center_x;
        double original_center_y = initial_drag_state.area.center_y;

        var radians = GLib.Math.atan2 (
            event_x - original_center_x,
            original_center_y - event_y
        );

        var added_rotation = radians * (180 / Math.PI);

        if (view_canvas.ctrl_is_pressed) {
            var step_num = GLib.Math.round (added_rotation / 15.0);
            added_rotation = 15.0 * step_num;
        }

        var rot = Utils.GeometryMath.matrix_rotation_component (initial_drag_state.area.transformation);

        foreach (var node in selection.nodes.values) {
            rotate_node (
                view_canvas,
                node.node,
                initial_drag_state,
                added_rotation * Math.PI / 180 - rot,
                original_center_x,
                original_center_y
            );
        }

        view_canvas.items_manager.compile_model ();
    }

    private static void rotate_node (
        ViewCanvas view_canvas,
        Lib2.Items.ModelNode node,
        InitialDragState initial_drag_state,
        double added_rotation,
        double rotation_center_x,
        double rotation_center_y
    ) {
        unowned var item = node.instance;
        if (item.components.transform != null) {
            var item_drag_data = initial_drag_state.item_data_map[item.id];

            var old_center_x = item_drag_data.item_geometry.area.center_x;
            var old_center_y = item_drag_data.item_geometry.area.center_y;

            var new_transform = item_drag_data.item_geometry.transformation_matrix;

            var tr = Cairo.Matrix.identity ();
            tr.rotate (added_rotation);

            if (old_center_x != rotation_center_x || old_center_y != rotation_center_y) {
                var new_center_delta_x = old_center_x - rotation_center_x;
                var new_center_delta_y = old_center_y - rotation_center_y;
                tr.transform_point (ref new_center_delta_x, ref new_center_delta_y);

                item.components.center = new Lib2.Components.Coordinates (
                    rotation_center_x + new_center_delta_x,
                    rotation_center_y + new_center_delta_y
                );
            }

            new_transform = Utils.GeometryMath.multiply_matrices (new_transform, tr);

            double new_rotation = Utils.GeometryMath.matrix_rotation_component (new_transform);

            if (item.components.transform != null) {
                new_rotation = GLib.Math.fmod (new_rotation + GLib.Math.PI * 2, GLib.Math.PI * 2);
                item.components.transform = item.components.transform.with_main_rotation (new_rotation);
            }

            item.mark_geometry_dirty ();
        }

        if (node.children != null && node.children.length > 0) {
            foreach (unowned var child in node.children.data) {
                rotate_node (
                    view_canvas,
                    child,
                    initial_drag_state,
                    added_rotation,
                    rotation_center_x,
                    rotation_center_y
                );
            }
        }
    }
}