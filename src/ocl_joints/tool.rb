module OclJoints

  # Interactive tool, one mode. Under the cursor a placed joint has priority, then a panel that
  # connects to another panel.
  #   - click a joint: select it, drag it along the edge (snaps to points) or type a distance;
  #     Delete erases it, Ctrl (tap) switches copy on and off as in SketchUp's Move tool
  #   - click a panel, then a connected panel:
  #       no possible third panel: a 2-panel joint at once (connector of the 2-panel table)
  #       else click the second panel again: a 2-panel joint, or click a third panel on the other
  #       face of the central panel, same axis: a 3-panel joint (connector of the 3-panel table)
  #     the new joint is in the middle of the contact and becomes the selected joint
  # Arrow keys on the selected joint: Left / Right other connector of its table, Alt + arrows turn
  # the edge component (3-panel joint: the two edge components in turn, first, second, first, ...),
  # Shift + arrows turn the face component. Without a selected joint
  # Left / Right select the 2-panel connector, Up / Down the 3-panel connector.
  class JointTool

    # Panels: edges only, OpenCutList's yellow; the line width and stipple show the state
    COLOR_PANEL = Sketchup::Color.new(254, 222, 11)
    PANEL_HOVER = [ 3, '' ].freeze        # [ width, stipple ]
    PANEL_SELECTED = [ 2, '' ].freeze
    PANEL_CANDIDATE = [ 1, '-' ].freeze
    COLOR_CANDIDATE = Sketchup::Color.new(254, 222, 11, 120)   # joint under the cursor
    COLOR_PAIR = Sketchup::Color.new(255, 140, 0)
    COLOR_SNAP_LINE = Sketchup::Color.new(120, 120, 120)
    LINE_WIDTH = 1
    GRIP_RADIUS = 4   # pixels
    OWN_TOL = 0.5 / 25.4
    COLOR_GRIP = Sketchup::Color.new(148, 0, 211)   # violet

    KEY_BACKSPACE = 8
    KEY_DELETE = 46
    KEY_ALT = 18
    ARROWS = [ VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN ].freeze
    SNAP = 3.0 / 25.4      # drag snaps to guide crossings and the edge middle closer than this
    PICK_APERTURE = 6
    TITLES = { rows: '2-panel', triples: '3-panel' }.freeze

    # Cursors are made once per SketchUp session
    def self.cursor(name)
      @cursors ||= {}
      @cursors[name] ||= UI.create_cursor(File.join(PLUGIN_ROOT, 'cursors', "#{name}.svg"), 2, 2)
    end

    def activate
      @model = Sketchup.active_model
      @ip = Sketchup::InputPoint.new
      @alt = false
      _refresh
      _reset
      @note = @model.active_path ? 'Close the open group or component for correct results.' : nil
      _status
    end

    def onSetCursor
      panels = @first || (@hover && @hover_pair.nil? && @selected.nil?)
      UI.set_cursor(JointTool.cursor(panels ? 'place' : (@copy ? 'copy' : 'edit')))
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      _status
      view.invalidate
    end

    def enableVCB?
      !@selected.nil?
    end

    def getExtents
      @model.bounds
    end

    def onCancel(reason, view)
      if reason == 2   # undo: the model changed
        _refresh
        _reset
      elsif @first
        _clear_panels
      else
        @model.select_tool(nil)
        return
      end
      _status
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      # mouse flags have a reliable Shift state: it corrects a missed key up
      @shift = (flags & CONSTRAIN_MODIFIER_MASK) != 0
      if @drag
        _drag(view, x, y)
      elsif @first
        # panel selection: joints are not picked
        @hover = _pick_panel(view, x, y)
        @hover_pair = nil
      else
        @hover_pair = _pick_pair(view, x, y)
        @hover = @hover_pair ? nil : _pick_panel(view, x, y)
        @hover = nil if @hover && !_joinable?(@hover)
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      pair = @first ? nil : _pick_pair(view, x, y)
      if pair
        @selected = pair
        _start_drag(x, y)
      else
        _panel_click(view, x, y)
      end
      # SketchUp's Edit > Delete takes the Delete key before the tool when its selection is not
      # empty: clear it, so Delete erases the selected joint
      @model.selection.clear if @selected && !@model.selection.empty?
      @copy = false unless @selected
      _status
      view.invalidate
    end

    # SketchUp sends the second click of a double-click only here: it is a normal click
    # (example: the second panel clicked twice makes a 2-panel joint)
    def onLButtonDoubleClick(flags, x, y, view)
      onLButtonDown(flags, x, y, view)
    end

    def onLButtonUp(flags, x, y, view)
      return unless @drag
      if @drag[:moved]
        @model.commit_operation
        @copy = false
      end
      @drag = nil
      @ip.clear
      _status
      view.invalidate
    end

    # The arrow keys always belong to the tool: true on key down and on key up stops SketchUp from
    # using them too (camera navigation).
    def onKeyDown(key, repeat, flags, view)
      handled = true
      if key == VK_SHIFT
        @shift = true
        handled = false
      elsif key == KEY_ALT
        @alt = true
      elsif key == COPY_MODIFIER_KEY
        # copy only for a selected joint
        _toggle_copy if !@ctrl_down && @selected && @first.nil?
        @ctrl_down = true
        handled = !@selected.nil?
      elsif ARROWS.include?(key)
        step = [ VK_RIGHT, VK_UP ].include?(key) ? 1 : -1
        horizontal = [ VK_LEFT, VK_RIGHT ].include?(key)
        if @selected && @first.nil?
          kind = _kind(@selected)
          rows = _rows(kind)
          if @alt && @selected.triple?
            # the two edge components in turn: count the Alt + arrow pushes on this joint
            @edge_turns = 0 unless @edge_turns_id == @selected.id
            _change_selected(edge_step: step, edge: @edge_turns.even? ? :edge : :edge2)
            @edge_turns += 1
            @edge_turns_id = @selected.id
          elsif @alt
            _change_selected(edge_step: step)
          elsif @shift
            _change_selected(face_step: step)
          elsif horizontal && !rows.empty?
            current = rows.index { |r| r[:name] == @selected.row } || _index(kind)
            _change_selected(row_index: (current + step) % rows.length)
          end
        else
          kind = horizontal ? :rows : :triples
          rows = _rows(kind)
          OclJoints.set_index(kind, (_index(kind) + step) % rows.length) unless rows.empty?
        end
      elsif @selected && [ KEY_DELETE, KEY_BACKSPACE ].include?(key)
        _erase
      else
        handled = false
      end
      if handled
        _status
        view.invalidate
      end
      handled || ARROWS.include?(key)
    end

    def onKeyUp(key, repeat, flags, view)
      @shift = false if key == VK_SHIFT
      @ctrl_down = false if key == COPY_MODIFIER_KEY
      @alt = false if key == KEY_ALT
      # Alt is kept too, so its release does not open the menu bar
      ARROWS.include?(key) || key == KEY_ALT
    end

    def onUserText(text, view)
      return unless @selected
      contact = _selected_contact
      return if contact.nil?
      begin
        distance = text.to_l.to_f
      rescue ArgumentError
        UI.beep
        return
      end
      l0, l1 = contact.segment
      l = _selected_l(contact)
      target = (l - l0 <= l1 - l ? l0 + distance : l1 - distance).clamp(l0, l1)
      @model.start_operation(@copy ? 'Copy joint' : 'Move joint', true)
      @selected = Scene.link(@selected)
      if @copy
        @selected = Scene.duplicate_pair(@selected)
        @pairs = {}
        @copy = false
      end
      _move_selected(contact, target - l)
      @model.commit_operation
      _status
      view.invalidate
    end

    def getMenu(menu, flags, x, y, view)
      %i[rows triples].each do |kind|
        rows = _rows(kind)
        next if rows.empty?
        menu.add_separator if kind == :triples
        rows.each_with_index do |row, i|
          item = menu.add_item("#{TITLES[kind]} #{i + 1}. #{row[:name]}") do
            if @selected && _kind(@selected) == kind
              _change_selected(row_index: i)
            else
              OclJoints.set_index(kind, i)
            end
            _status
            view.invalidate
          end
          menu.set_validation_proc(item) { i == _index(kind) ? MF_CHECKED : MF_ENABLED }
        end
      end
      menu.add_separator
      if @selected
        menu.add_item('Erase joint') { _erase; _status; view.invalidate }
      end
      menu.add_item('Settings...') { OclJoints.show_settings }
      true
    end

    def draw(view)
      if @first
        candidates = @second ? @thirds : @candidates
        candidates.each_value { |c| _draw_panel(view, c[:panel], PANEL_CANDIDATE) }
        _draw_panel(view, @first, PANEL_SELECTED)
        _draw_panel(view, @second[:panel], PANEL_SELECTED) if @second
      end
      _draw_panel(view, @hover, PANEL_HOVER) if @hover && !_selected_panel?(@hover) && _clickable?(@hover)
      _draw_pair(view, @hover_pair, COLOR_CANDIDATE, LINE_WIDTH) if @hover_pair && @hover_pair != @selected
      _draw_pair(view, @selected, COLOR_PAIR, LINE_WIDTH) if @selected
      _draw_grip(view) if @selected
      _draw_snap(view) if @drag
    end

    private

    def _refresh
      @panels = Scene.panels(@model)
      @panel_by_key = @panels.to_h { |p| [ p.key, p ] }
      @panel_lines = {}
      @lines = {}
      @features = {}
      @pairs = {}
      @joinable = {}
    end

    def _reset
      _clear_panels
      @hover_pair = nil
      @selected = nil
      @drag = nil
      @copy = false
    end

    def _clear_panels
      @hover = nil
      @first = nil
      @second = nil
      @candidates = {}
      @thirds = {}
    end

    # A panel that connects (edge to face) to at least one other panel
    def _joinable?(panel)
      return @joinable[panel.key] if @joinable.key?(panel.key)
      @joinable[panel.key] = @panels.any? { |p| p.key != panel.key && Joint.joint(panel.box, p.box) }
    end

    # A click on this panel does something: the second panel again, a candidate, or a new first panel
    def _clickable?(panel)
      return true if @first.nil?
      return @thirds.key?(panel.key) || panel.key == @second[:panel].key if @second
      @candidates.key?(panel.key) || _joinable?(panel)
    end

    def _selected_panel?(panel)
      [ @first, @second && @second[:panel] ].compact.any? { |p| p.key == panel.key }
    end

    # Connector tables: :rows (2-panel) and :triples (3-panel)
    def _rows(kind)
      OclJoints.config[kind]
    end

    def _index(kind)
      OclJoints.index(kind).clamp(0, [ _rows(kind).length - 1, 0 ].max)
    end

    def _row(kind)
      _rows(kind)[_index(kind)]
    end

    def _kind(pair)
      pair.triple? ? :triples : :rows
    end

    # --- new joint ---

    def _panel_click(view, x, y)
      panel = _pick_panel(view, x, y)
      if panel.nil?
        _clear_panels
        @selected = nil
      elsif @second && (third = @thirds[panel.key])
        _add_triple(@second, third)
        _clear_panels
      elsif @second && panel.key == @second[:panel].key
        _add_pair(@second)
        _clear_panels
      elsif @first && !@second && (candidate = @candidates[panel.key])
        _set_second(panel, candidate)
        if @thirds.empty? || _row(:triples).nil?
          _add_pair(@second)
          _clear_panels
        end
      elsif @first && panel.key == @first.key
        _clear_panels
      elsif _joinable?(panel)
        _set_first(panel)
      end
    rescue StandardError => e
      _clear_panels
      UI.messagebox("OCL Joints error: #{e.message}\n\n#{e.backtrace.first(5).join("\n")}")
    end

    def _set_first(panel)
      _clear_panels
      @selected = nil
      @first = panel
      @panels.each do |p|
        next if p.key == panel.key
        contact, first_is_edge = Joint.joint(panel.box, p.box)
        @candidates[p.key] = { panel: p, contact: contact, first_is_edge: first_is_edge } if contact
      end
    end

    # Second panel: a third panel can make a 3-panel joint if it touches the other face of the
    # face panel on the same axis
    def _set_second(panel, candidate)
      edge_panel, face_panel = candidate[:first_is_edge] ? [ @first, panel ] : [ panel, @first ]
      @second = { panel: panel, edge_panel: edge_panel, face_panel: face_panel, contact: candidate[:contact] }
      @thirds = {}
      @panels.each do |p|
        next if p.key == edge_panel.key || p.key == face_panel.key
        contact, segment = Joint.third(candidate[:contact], p.box, face_panel.box)
        @thirds[p.key] = { panel: p, contact: contact, segment: segment } if contact
      end
    end

    # Definitions of a connector row inside an open operation; on failure the operation is
    # aborted, a message shows and nil is returned
    def _definitions_for(row, kind)
      library = OclJoints.library
      edge_def = Scene.definition(@model, row[:edge], library)
      face_def = Scene.definition(@model, row[:face], library)
      missing = [ [ 'Edge', row[:edge], edge_def ], [ 'Face', row[:face], face_def ] ].reject { |*, d| d }
      return [ edge_def, face_def ] if missing.empty?
      @model.abort_operation
      @note = "Component not found: #{missing.map { |_, n, _| "'#{n}'" }.join(', ')}."
      UI.messagebox("#{TITLES[kind]} connector '#{row[:name]}': component not found.\n\n" +
                    missing.map { |role, n, _| "#{role} component: '#{n}'" }.join("\n") +
                    "\n\nThe name must be the name of a component definition or instance in the model, " \
                    "or of a .skp file in a library folder (Settings).")
      nil
    end

    # One 2-panel joint in the middle of the contact, with the predicted turns; it becomes the selected joint
    def _add_pair(second)
      row = _row(:rows)
      if row.nil?
        @note = 'The 2-panel connector table is empty. Open Settings.'
        return
      end
      edge_panel, face_panel, contact = second.values_at(:edge_panel, :face_panel, :contact)
      @model.start_operation('Add joint', true)
      edge_def, face_def = _definitions_for(row, :rows)
      return if edge_def.nil?

      point = Joint.joint_point(contact, contact.segment.sum / 2.0)
      frames = Joint.frames(contact)
      prediction = Joint.predict(contact, point, edge_panel.box, _features(edge_def),
                                 face_panel.box, _features(face_def), row[:learned])
      ke, kf = prediction[:edge], prediction[:face]
      id = Scene.new_pair_id
      edge = Scene.add(edge_panel, edge_def, Scene.world_transformation(point, frames[:edge], ke), id, 'edge', row[:name], ke)
      face = Scene.add(face_panel, face_def, Scene.world_transformation(point, frames[:face], kf), id, 'face', row[:name], kf)
      @model.commit_operation

      @selected = Scene::Pair.new(id, row[:name], Scene::Part.new(edge_panel, edge), Scene::Part.new(face_panel, face))
      _added_note(@selected)
    rescue StandardError => e
      UI.messagebox("OCL Joints error: #{e.message}\n\n#{e.backtrace.first(5).join("\n")}")
    end

    # One 3-panel joint in the middle of the common part: the face component (through hole) on the
    # face to the first edge panel, an edge component in each edge panel
    def _add_triple(second, third)
      row = _row(:triples)
      if row.nil?
        @note = 'The 3-panel connector table is empty. Open Settings.'
        return
      end
      edge_panel, face_panel, contact = second.values_at(:edge_panel, :face_panel, :contact)
      @model.start_operation('Add joint', true)
      edge_def, face_def = _definitions_for(row, :triples)
      return if edge_def.nil?

      point = Joint.joint_point(contact, third[:segment].sum / 2.0)
      id = Scene.new_pair_id
      edge, face, edge2 = _place_triple(row, edge_def, face_def, edge_panel, face_panel, third[:panel],
                                        contact, third[:contact], point, id)
      @model.commit_operation
      @selected = Scene::Pair.new(id, row[:name], edge, face, edge2)
      _added_note(@selected)
    end

    # Adds the 3 components of a 3-panel joint; turns predicted, or given as [ edge, face, edge2 ]
    def _place_triple(row, edge_def, face_def, edge_panel, face_panel, edge2_panel, contact, contact2, point, id, turns = nil)
      point2 = Joint.opposite_point(contact2, point)
      frames = Joint.frames(contact)
      frames2 = Joint.frames(contact2)
      ke, kf, ke2 = turns || begin
        p1 = Joint.predict(contact, point, edge_panel.box, _features(edge_def), face_panel.box, _features(face_def), row[:learned])
        p2 = Joint.predict(contact2, point2, edge2_panel.box, _features(edge_def), face_panel.box, [], row[:learned])
        [ p1[:edge], p1[:face], p2[:edge] ]
      end
      add = lambda do |panel, definition, pt, axes, k, role|
        Scene::Part.new(panel, Scene.add(panel, definition, Scene.world_transformation(pt, axes, k), id, role, row[:name], k, triple: true))
      end
      [ add.call(edge_panel, edge_def, point, frames[:edge], ke, 'edge'),
        add.call(face_panel, face_def, point, frames[:face], kf, 'face'),
        add.call(edge2_panel, edge_def, point2, frames2[:edge], ke2, 'edge') ]
    end

    def _added_note(pair)
      shared = pair.parts.map { |part| part.panel.definition }.uniq.select { |d| d.instances.length > 1 }
      @note = "Joint added: #{pair.row}."
      unless shared.empty?
        @note += ' Also in other instances: ' + shared.map { |d| "#{d.name} (#{d.instances.length})" }.join(', ') + '.'
      end
    end

    def _features(definition)
      @features[definition] ||= Scene.feature_points(definition)
    end

    # --- selected joint ---

    def _start_drag(x, y)
      contact = _selected_contact
      return if contact.nil?
      guides = Scene.guides(@model, @selected.parts.map(&:panel).uniq(&:key))
      snaps = Joint.positions(contact, guides) + [ contact.segment.sum / 2.0 ]
      l = _selected_l(contact)
      @drag = { contact: contact, l: l, start_l: l, snaps: snaps, moved: false, original: nil, snap_point: nil }
    end

    # Copy on: the moving joint becomes a new copy and the original goes back to the drag start.
    # Copy off: the copy is erased and the original moves to the current position.
    def _toggle_copy
      @copy = !@copy
      return unless @drag && @drag[:moved]
      contact = @drag[:contact]
      if @copy
        original = @selected
        @selected = Scene.duplicate_pair(original)
        @drag[:original] = original
        _move_pair(original, contact, @drag[:start_l] - @drag[:l])
      elsif (original = @drag[:original])
        @selected.parts.each { |part| part.instance.erase! if part.instance.valid? }
        @selected = original
        @drag[:original] = nil
        _move_pair(original, contact, @drag[:l] - @drag[:start_l])
      end
      @pairs = {}
    end

    # The joint follows the cursor along the edge line. An inference point (end, middle, intersection,
    # guide point, ... as in SketchUp's Move tool) has priority; it is projected onto the edge line.
    # Without it the joint snaps to guide-line crossings and the edge middle.
    def _drag(view, x, y)
      contact = @drag[:contact]
      @ip.pick(view, x, y)
      @drag[:snap_point] = nil
      if @ip.valid? && @ip.degrees_of_freedom == 0 && !_own_inference?
        l = Joint.dot(Joint.sub(@ip.position.to_a, contact.corner), contact.l_axis).clamp(*contact.segment)
        @drag[:snap_point] = @ip.position
        view.tooltip = @ip.tooltip
      else
        ray = view.pickray(x, y)
        l = Joint.nearest_l(contact, ray[0].to_a, ray[1].to_a).clamp(*contact.segment)
        snap = @drag[:snaps].min_by { |s| (s - l).abs }
        l = snap if snap && (snap - l).abs < SNAP
        view.tooltip = ''
      end
      delta = l - @drag[:l]
      return if delta.abs < 1e-6
      unless @drag[:moved]
        @model.start_operation(@copy ? 'Copy joint' : 'Move joint', true)
        @selected = Scene.link(@selected)
        @drag[:moved] = true
        if @copy
          @drag[:original] = @selected
          @selected = Scene.duplicate_pair(@selected)
          @pairs = {}
        end
      end
      _move_selected(contact, delta)
      @drag[:l] = l
      _status
    end

    # Inference on the moving components themselves: not used, it would follow the joint.
    # By entity (vertex, edge, face of the components) and by position: points such as a circle
    # center have no entity of the component, so a point inside a component box is not used either.
    def _own_inference?
      position = @ip.position
      return true if @selected.parts.any? { |part| _world_bounds(part).contains?(position) }
      entity = @ip.vertex || @ip.edge || @ip.face
      return false if entity.nil?
      parent = entity.is_a?(Sketchup::Vertex) ? entity.edges.first&.parent : entity.parent
      return false unless parent.is_a?(Sketchup::ComponentDefinition)
      own = @selected.parts.flat_map { |part| _definitions(part.instance.definition) }
      own.include?(parent)
    end

    # World box of a placed component, a little larger (points on its surface are inside)
    def _world_bounds(part)
      t = part.transformation
      local = part.instance.definition.bounds
      box = Geom::BoundingBox.new
      (0..7).each { |i| box.add(local.corner(i).transform(t)) }
      grow = Geom::Vector3d.new(OWN_TOL, OWN_TOL, OWN_TOL)
      box.add(box.min.offset(grow.reverse), box.max.offset(grow))
      box
    end

    def _definitions(definition, found = [])
      return found if found.include?(definition)
      found << definition
      definition.entities.each do |e|
        _definitions(e.definition, found) if e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
      end
      found
    end

    def _move_selected(contact, delta)
      _move_pair(@selected, contact, delta)
    end

    def _move_pair(pair, contact, delta)
      vector = Joint.mul(contact.l_axis, delta)
      pair.parts.each { |part| Scene.move(part, vector) }
    end

    # Contact of the edge and face panels; for a 3-panel joint its segment is the common part
    # with the second edge panel
    def _selected_contact
      contact = Joint.contact(@selected.edge.panel.box, @selected.face.panel.box)
      return contact if contact.nil? || !@selected.triple?
      _, segment = Joint.third(contact, @selected.edge2.panel.box, @selected.face.panel.box)
      return contact if segment.nil?
      contact = contact.dup
      contact.segment = segment
      contact
    end

    def _selected_l(contact)
      Joint.dot(Joint.sub(@selected.edge.transformation.origin.to_a, contact.corner), contact.l_axis)
    end

    # Replaces the components of the selected joint (same pair id and position):
    #   row_index:  other connector of its table, turns predicted as for a new joint
    #   edge_step / face_step: next allowed turn of the edge components / the face component
    #   edge: for a 3-panel joint, the edge component edge_step turns (:edge or :edge2; nil: both)
    def _change_selected(row_index: nil, edge_step: nil, face_step: nil, edge: nil)
      pair = @selected
      kind = _kind(pair)
      contact = Joint.contact(pair.edge.panel.box, pair.face.panel.box)
      contact2 = pair.triple? ? Joint.contact(pair.edge2.panel.box, pair.face.panel.box) : nil
      return if contact.nil? || (pair.triple? && contact2.nil?)
      rows = _rows(kind)
      index = row_index || rows.index { |r| r[:name] == pair.row }
      row = index ? rows[index] : nil
      if row.nil? && row_index.nil?
        # hand-placed pair of components that are not in the table: turn them as they are
        row = { name: pair.row, edge: pair.edge.instance.definition.name, face: pair.face.instance.definition.name }
      end
      edge_panel, face_panel, edge2_panel = pair.edge.panel, pair.face.panel, pair.edge2&.panel
      @model.start_operation('Change joint', true)
      pair = @selected = Scene.link(@selected)
      edge_def, face_def = _definitions_for(row, kind)
      return if edge_def.nil?

      point = pair.edge.transformation.origin.to_a
      frames = Joint.frames(contact)
      prediction = Joint.predict(contact, point, edge_panel.box, _features(edge_def),
                                 face_panel.box, _features(face_def), row[:learned])
      ke, kf = prediction[:edge], prediction[:face]
      if pair.triple?
        point2 = Joint.opposite_point(contact2, point)
        prediction2 = Joint.predict(contact2, point2, edge2_panel.box, _features(edge_def), face_panel.box, [], row[:learned])
        ke2 = prediction2[:edge]
      end
      if row_index.nil?
        ke = Scene.turn(pair.edge, frames[:edge])
        kf = Scene.turn(pair.face, frames[:face])
        ke = Joint.next_option(prediction[:edge_options], ke, edge_step) if edge_step && edge != :edge2
        kf = Joint.next_option(prediction[:face_options], kf, face_step) if face_step
        if pair.triple?
          ke2 = Scene.turn(pair.edge2, Joint.frames(contact2)[:edge])
          ke2 = Joint.next_option(prediction2[:edge_options], ke2, edge_step) if edge_step && edge != :edge
        end
      end

      pair.parts.each { |part| part.instance.erase! if part.instance.valid? }
      if pair.triple?
        edge, face, edge2 = _place_triple(row, edge_def, face_def, edge_panel, face_panel, edge2_panel,
                                          contact, contact2, point, pair.id, [ ke, kf, ke2 ])
      else
        edge = Scene::Part.new(edge_panel, Scene.add(edge_panel, edge_def, Scene.world_transformation(point, frames[:edge], ke), pair.id, 'edge', row[:name], ke))
        face = Scene::Part.new(face_panel, Scene.add(face_panel, face_def, Scene.world_transformation(point, frames[:face], kf), pair.id, 'face', row[:name], kf))
      end
      @model.commit_operation

      @selected = Scene::Pair.new(pair.id, row[:name], edge, face, edge2)
      @hover_pair = nil
      @pairs = {}
      OclJoints.set_index(kind, index) if index
      # learn the turns only when the inner side is known: they are relative to it
      if index && row_index.nil? && contact.inner
        config = OclJoints.config
        config[kind][index] = row.merge(learned: { edge: ke, face: kf })
        OclJoints.save_config(config)
      end
      @note = "Joint: #{row[:name] || 'not in the table'}."
    end

    def _erase
      @model.start_operation('Erase joint', true)
      @selected.parts.each { |part| part.instance.erase! if part.instance.valid? }
      @model.commit_operation
      @pairs = {}
      @selected = nil
      @hover_pair = nil
      @note = 'Joint erased.'
    end

    # --- picking ---

    def _pick_panel(view, x, y)
      _picked_paths(view, x, y).each do |full|
        (1..full.length).each do |n|
          panel = @panel_by_key[full[0...n].map(&:entityID).join('/')]
          return panel if panel
        end
      end
      nil
    end

    def _pick_pair(view, x, y)
      _picked_paths(view, x, y).each do |full|
        # the component directly inside a panel
        j = (1...full.length).find { |n| @panel_by_key.key?(full[0...n].map(&:entityID).join('/')) }
        next if j.nil?
        panel = @panel_by_key[full[0...j].map(&:entityID).join('/')]
        instance = full[j]
        next unless Scene.feature?(instance)
        key = "#{panel.key}/#{instance.entityID}"
        unless @pairs.key?(key)
          pair = instance.get_attribute(Scene::DICTIONARY, 'pair_id') && Scene.pair(@panels, panel, instance)
          @pairs[key] = pair || Scene.manual_pair(@panels, panel, instance, _rows(:rows))
        end
        return @pairs[key] if @pairs[key]
      end
      nil
    end

    # Full paths from the model root at the cursor; paths of the best face first
    def _picked_paths(view, x, y)
      ph = view.pick_helper(x, y, PICK_APERTURE)
      active = @model.active_path || []
      face = ph.picked_face
      paths = (0...ph.count).map { |i| [ ph.leaf_at(i) == face && face ? 0 : 1, active + ph.path_at(i).to_a ] }
      paths.sort_by(&:first).map(&:last)
    end

    # --- drawing ---

    def _draw_panel(view, panel, style)
      points = @panel_lines[panel.key] ||=
        Scene.lines(panel.definition, with_features: false).map { |p| p.transform(panel.transformation) }
      return if points.empty?
      view.line_width, view.line_stipple = style
      view.drawing_color = COLOR_PANEL
      view.draw(GL_LINES, points)
      view.line_stipple = ''
    end

    def _draw_pair(view, pair, color, width)
      pair.parts.each do |part|
        next unless part.instance.valid?
        _draw_component(view, part.instance.definition, part.transformation, color, width)
      end
    end

    # Components are inside the panels, so they are drawn over the model (2D)
    def _draw_component(view, definition, transformation, color, width)
      points = @lines[definition] ||= Scene.lines(definition)
      return if points.empty?
      view.line_width = width
      view.drawing_color = color
      view.draw2d(GL_LINES, points.map { |pt| view.screen_coords(pt.transform(transformation)) })
    end

    # Grip point of the selected joint (the point that snaps): a violet point with a white outline
    def _draw_grip(view)
      point = if @drag
                Geom::Point3d.new(*Joint.joint_point(@drag[:contact], @drag[:l]))
              elsif @selected.edge.instance.valid?
                @selected.edge.transformation.origin
              end
      return if point.nil?
      c = view.screen_coords(point)
      [ [ GRIP_RADIUS + 1.5, Sketchup::Color.new(255, 255, 255) ], [ GRIP_RADIUS, COLOR_GRIP ] ].each do |r, color|
        disc = (0...20).map { |i| a = i * Math::PI / 10; Geom::Point3d.new(c.x + r * Math.cos(a), c.y + r * Math.sin(a), 0) }
        view.drawing_color = color
        view.draw2d(GL_POLYGON, disc)
      end
    end

    # Inference marker and a dashed line from it to the joint
    def _draw_snap(view)
      point = @drag[:snap_point]
      return if point.nil?
      @ip.draw(view)
      target = Geom::Point3d.new(*Joint.joint_point(@drag[:contact], @drag[:l]))
      return if point.distance(target) < 1e-6
      view.line_width = 1
      view.line_stipple = '-'
      view.drawing_color = COLOR_SNAP_LINE
      view.draw(GL_LINES, [ point, target ])
      view.line_stipple = ''
    end

    # --- status bar ---

    def _status
      connectors = %i[rows triples].map do |kind|
        row = _row(kind)
        "#{TITLES[kind]}: #{row ? row[:name] : 'none'}."
      end.join(' ')
      text = if @second
               "Click the second panel again: 2-panel joint. Or click a third panel: 3-panel joint (#{@thirds.length} found). Esc: cancel."
             elsif @first
               "Select a connected panel (#{@candidates.length} found). Click the panel again or Esc: cancel."
             elsif @selected
               "Drag: #{@copy ? 'copy' : 'move'} along the edge. Ctrl: copy #{@copy ? 'off' : 'on'}. Left/Right: connector. " \
               'Alt+arrows: turn edge part. Shift+arrows: turn face part. Type a distance from the nearest end. ' \
               'Delete: erase. Click a panel: new joint. Esc: exit.'
             else
               'Click a joint to select it, or click two (three) panels: new joint. Left/Right: 2-panel connector. Up/Down: 3-panel connector. Esc: exit.'
             end
      # the note first: the status bar cuts long texts
      Sketchup.status_text = [ @note, connectors, text ].compact.join(' ')
      return unless @selected && (contact = _selected_contact)
      l0, l1 = contact.segment
      l = _selected_l(contact)
      Sketchup.vcb_label = 'Distance'
      Sketchup.vcb_value = Sketchup.format_length([ l - l0, l1 - l ].min)
    end

  end

end
