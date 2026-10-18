# OCL Joints

SketchUp extension. It places pairs of surface components (minifix, confirmat, dowels) where two panels connect.
It is a companion of [OpenCutList](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension)
and [ocl-viyar](https://github.com/agav/ocl-viyar): ocl-viyar exports the placed `f_` components as drillings.

## Joint

A joint is a contact between two panels:

- An edge face of one panel (the **edge panel**) touches the front or back face of the other panel (the **face panel**).
- The contact area must be larger than zero.

The **face component** goes into the face panel. The **edge component** goes into the edge panel.

## Install

1. Run `python3 tools/build_rbz.py`. The file `dist/ocl_joints_<version>.rbz` is made.
2. In SketchUp, open **Extensions > Extension Manager > Install Extension**. Select the `.rbz` file.

For development, copy `tools/dev_loader.rb` into the SketchUp `Plugins` folder. SketchUp then loads the code from
`C:/prj/ocl-joints`. After a change, select **Extensions > OCL Joints > Reload extension (dev)**.

## Place joints

1. Click **Place joints** (toolbar or **Extensions > OCL Joints**).
2. Move the cursor over the model. The tool highlights the panel under the cursor.
3. Click a panel. The tool highlights all panels that connect to it.
4. Click one of the connected panels. The tool shows the component pairs: blue is the edge component, red is the face component.
5. If necessary, turn the components:
   - **Alt + arrow**: turn the edge component 90°.
   - **Shift + arrow**: turn the face component 90°.
   - **Right** or **Up** turns in one direction, **Left** or **Down** turns in the other direction.
6. Push **Enter** or click to add the components. Push **Esc** to cancel.
7. The tool goes to edit mode. The last added pair is selected: you can move it or erase it immediately (see [Edit joints](#edit-joints)).
   Push **Esc** to exit the tool.

To select the connector:

- Push **Right** for the next row of the table. Push **Left** for the previous row.
- Push **1**–**9** for rows 1–9.
- Right-click and select the row.

If the pairs show, the tool changes them to the new connector immediately.

### Position

- The tool uses the **edge middle line**: the line at half the thickness of the edge panel, in the contact plane.
- The tool uses only the length where the panels touch.
- A guide line is used if it lies in the contact plane and is perpendicular to the edge line.
  The tool looks for guide lines in the model root, in the parent groups of the two panels and in the two panels.
- The tool adds one pair at each crossing of a guide line with the edge middle line.
- If there is no guide line, the tool adds one pair at the middle of the contact.

### Rotation

The tool calculates a frame for each component:

- **Z** is the outward normal of the panel surface (the f_ convention of ocl-viyar: holes go in −Z).
- **Y** points to the inner side: the side where the face panel extends more. Example: the cam of a minifix goes on
  the top face of a cabinet bottom and on the bottom face of a cabinet top.

The tool tries the four 90° turns of each component and selects one:

1. It rejects a turn that puts a hole outside its panel or, on the contact plane, outside the contact area.
2. It prefers the turns where the holes of the two components align (example: dowels).
3. It prefers the learned turns. When you add a pair, the tool keeps its turns for this connector.
4. It prefers the turn that puts the edge component holes (example: the cam) on the inner side.

The tool learns only if the inner side is known. For a shelf in the middle, the two sides are equal, so the tool does not learn.

### Shared definitions

The components go into the panel definition. If a definition has more instances, all instances get the components.
The status bar shows these definitions. To drill one panel only, make it unique before you add the joint.

## Edit joints

1. Click **Edit joints**, or right-click in the tool and select **Edit mode**. To go back to place mode, click **Place joints** or select **Place mode**.
2. Move the cursor over a placed component. The tool highlights the pair.
3. Click to select the pair.
4. Drag to move the pair along the edge. The pair snaps to guide-line crossings and to the edge middle.
5. To set an exact position, type a distance. The distance is from the nearest end of the contact.
6. To copy the pair, push **Ctrl** one time (copy on), then drag or type a distance. The original pair stays.
   Push **Ctrl** again to set copy off. The cursor shows a **+** when copy is on. Copy goes off after each move.
7. To change the selected pair, use the same keys as in place mode:
   - **Left / Right**: change the pair to the previous / next connector of the table. The tool selects the turns again.
   - **Alt + arrow**: turn the edge component 90°.
   - **Shift + arrow**: turn the face component 90°.
8. To erase the pair, push **Delete** or right-click **Erase pair**.
9. Push **Esc** to exit the tool. Click an empty area to clear the selection.

Each placed component has the attributes `ocl_joints / pair_id`, `role` (`edge` or `face`) and `row`.
The tool uses them to find the other component of the pair.

You can also edit components that you placed by hand. The tool finds a pair if:

- Both components are directly in the panels (not inside other groups), and their names start with `f_` or `g_`.
- The two panels connect (edge to face).
- The component origins are at the same point on the contact plane (1 mm tolerance).

The tool gets the connector name from the table (face and edge component names). When you move, copy, turn or change
the pair, the tool writes the attributes.

### Cursor

- Place mode: arrow with a yellow panel corner.
- Edit mode: arrow with orange move arrows.
- Edit mode, copy on: the same, with an orange **+**.

## Settings

**Extensions > OCL Joints > Settings...** opens the connector table:

| Name | Face component | Edge component |
|---|---|---|
| minifix | `f_d5x11.5` | `g_minifix-edge` |
| minifix + dowels | `g_minifix_shkant_front` | `g_minifx_shkant_edge` |
| confirmat | `f_d7xFc` | `f_d4.5x34` |
| dowel 8 | `f_d8x12` | `f_d8.5x25` |

These defaults are the pairs of `lm.skp`.

- The tool uses the component definition of the model.
- If the model does not have it, the tool loads `<name>.skp` from a library folder (subfolders too).
- The table is saved in `%APPDATA%\ocl_joints\config.json`. **Import** and **Export** copy it to and from a JSON file.

### Component rules

- The component origin is on the panel surface. Its Z axis is the outward normal of that surface.
- In a `g_` component, the tool uses the origins of the `f_` components inside it as hole positions.

## Limits

- Close all groups before you use the tool. The tool calculates positions from the model root.
- A panel is a group or component with faces of its own and a name that does not start with `f_` or `g_`.
- The panel box comes from the definition axes. A panel that is turned inside its definition gets a wrong box.
- In a mirrored panel, the tool mirrors the component along the edge line. Components that are not symmetric along the edge line can change.

## Tests

```
ruby test/test_joint.rb
ruby test/test_config.rb
```

The tests cover the geometry and the settings. They do not need SketchUp.
