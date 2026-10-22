# OCL Joints

SketchUp extension. It places surface components (minifix, confirmat, dowels) where two or three panels connect.
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

## Use the tool

Click **Joints** (toolbar or **Extensions > OCL Joints**). The tool has one mode.

Under the cursor, the tool highlights:

1. a placed joint (it has priority), or
2. a panel that connects to a different panel (yellow edges).

### Add a joint

1. Click a highlighted panel. The tool highlights all panels that connect to it (dashed edges).
2. Click one of the connected panels.
   - If no third panel is possible, the tool adds a 2-panel joint immediately.
   - If a third panel is possible, the tool highlights the possible third panels and waits:
     - Click the second panel again: the tool adds a 2-panel joint.
     - Click a third panel: the tool adds a 3-panel joint.
3. The tool selects the new joint. You can move, turn or erase it immediately.

To cancel the panel selection, push **Esc**, click the first panel again or click an empty area.

A joint goes on the **edge middle line**: the line at half the thickness of the edge panel, in the contact plane.
The tool uses only the length where the panels touch. The tool puts the joint in the middle of this length.

#### 3-panel joint

A 3-panel joint connects a central panel and two edge panels, one on each face of the central panel.
Example: a metal cylinder in a through hole of a partition, with an eccentric connector in each shelf.

- The first two panels must be one edge panel and the central panel (in any order).
- The third panel must touch the other face of the central panel with its edge.
- The middle lines of the two edge panels must be on one axis (0.5 mm tolerance). Example: a 16 mm shelf and an 18 mm
  shelf at the same bottom height are not on one axis.
- The joint uses only the length where all three panels touch.
- The face component goes on the face to the first edge panel. It must be a through hole (for example `f_d10xF`).
- Each edge panel gets the edge component. The tool turns each one to the inner side of its own contact.

#### Connector

The joint uses the current connector of its table. The status bar shows both current connectors.

- **Left / Right**: select the 2-panel connector.
- **Up / Down**: select the 3-panel connector.
- Right-click: select a connector from the list.

### Select and change a joint

1. Move the cursor over a placed component. The tool highlights the joint.
2. Click to select the joint.
3. Drag to move the joint along the edge.
   - The joint snaps to points, as in the SketchUp Move tool: ends, midpoints, intersections, guide points.
     The tool puts the joint where the point is on the edge line (a dashed line shows it).
   - Without a point, the joint snaps to guide-line crossings and to the edge middle.
4. To set an exact position, type a distance. The distance is from the nearest end of the contact.
5. To copy the joint, push **Ctrl** one time (copy on), then drag or type a distance. The original pair stays.
   Push **Ctrl** again to set copy off. The cursor shows a **+** when copy is on. Copy goes off after each move.
6. To change the joint:
   - **Left / Right**: change the joint to the previous / next connector of its table. The tool selects the turns again.
   - **Alt + arrow**: turn the edge component 90°. In a 3-panel joint, each push turns one edge component, in turn:
     first, second, first, second. With two possible turns (for example minifix), four pushes bring the joint back.
   - **Shift + arrow**: turn the face component 90°.
7. To erase the joint, push **Delete** or right-click **Erase joint**.
   When a joint becomes selected, the tool clears the SketchUp selection: SketchUp would erase that selection with **Delete**.
8. Push **Esc** to exit the tool. Click an empty area to clear the selection.

Each placed component has the attributes `ocl_joints / pair_id`, `role` (`edge` or `face`) and `row`.
A 3-panel joint also has `kind` = `triple`. The tool uses the attributes to find the other components of the joint.

You can also edit 2-panel joints that you placed by hand. The tool finds a pair if:

- Both components are directly in the panels (not inside other groups), and their names start with `f_` or `g_`.
- The two panels connect (edge to face).
- The component origins are at the same point on the contact plane (1 mm tolerance).

The tool gets the connector name from the table (face and edge component names). When you move, copy, turn or change
the pair, the tool writes the attributes.

### Rotation

The tool calculates a frame for each component:

- **Z** is the outward normal of the panel surface (the f_ convention of ocl-viyar: holes go in −Z).
- **Y** points to the inner side: the side where the face panel extends more. Example: the cam of a minifix goes on
  the top face of a cabinet bottom and on the bottom face of a cabinet top.

The tool tries the four 90° turns of each component and selects one:

1. It rejects a turn that puts a hole outside its panel or, on the contact plane, outside the contact area.
2. It prefers the turns where the holes of the two components align (example: dowels).
3. It prefers the learned turns. When you turn a pair, the tool keeps its turns for this connector.
4. It prefers the turn that puts the edge component holes (example: the cam) on the inner side.

The tool learns only if the inner side is known. For a shelf in the middle, the two sides are equal, so the tool does not learn.

### Shared definitions

The components go into the panel definition. If a definition has more instances, all instances get the components.
The status bar shows these definitions. To drill one panel only, make it unique before you add the joint.

### Cursor

- Select a joint: arrow with a bolt.
- Copy on: the same, with an orange **+**.
- Panel under the cursor, or panel selection: arrow with a bolt and a yellow panel corner.

## Settings

**Extensions > OCL Joints > Settings...** opens the connector tables.

**2-panel connectors:**

| Name | Face component | Edge component |
|---|---|---|
| minifix | `f_d5x11.5` | `g_minifix-edge` |
| minifix + dowels | `g_minifix_shkant_front` | `g_minifx_shkant_edge` |
| confirmat | `f_d7xFc` | `f_d4.5x34` |
| dowel 8 | `f_d8x12` | `f_d8.5x25` |

These defaults are the pairs of `lm.skp`.

**3-panel connectors:** Name, Face component (through hole in the central panel), Edge component (for both edge panels).
This table is empty at the start.

- The tool uses the component definition of the model.
- If the model does not have it, the tool loads `<name>.skp` from a library folder (subfolders too), and then from the
  `components` folder of the plugin.
- The tables are saved in `%APPDATA%\ocl_joints\config.json`. **Import** and **Export** copy it to and from a JSON file.

### Components and tables shipped with the plugin

The plugin can contain the connector components (`src/ocl_joints/components/*.skp`) and the default tables
(`src/ocl_joints/defaults.json`). A new installation starts with these tables, and **Defaults** in Settings loads them.

To update them from your model:

1. Open a model that contains all components of the tables.
2. Select **Extensions > OCL Joints > Save components and tables to plugin (dev)**.
3. The plugin saves each component as `<name>.skp` and the current tables as `defaults.json`.
   With the development loader, the files go into the repository. Commit them.

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
