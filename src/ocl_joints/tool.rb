module OclJoints

  # Interactive tool, one mode:
  #   - select a placed pair, drag it along the edge (snaps to points) or type a distance;
  #     Delete erases it, Ctrl (tap) switches copy on and off as in SketchUp's Move tool
  #   - hold Alt and click two connected panels: the tool adds one pair in the middle of the contact
  #     and selects it; releasing Alt before the second panel cancels the panel selection
  # Arrow keys on the selected pair: Left / Right other connector, Alt + arrows turn the edge
  # component, Shift + arrows turn the face component. Without a selected pair Left / Right select
  # the connector for the next pair.
  class JointTool

    # Same colors as OpenCutList's part highlight
    COLOR_PART = Sketchup::Color.new(254, 222, 11, 200)
    COLOR_PART_HIGHLIGHTED = Sketchup::Color.new(254, 222, 11, 255)
    COLOR_CANDIDATE = Sketchup::Color.new(254, 222, 11, 120)
    COLOR_PAIR = Sketchup::Color.new(255, 140, 0)
    COLOR_SNAP_LINE = Sketchup::Color.new(120, 120, 120)
    LINE_WIDTH = 1

    KEY_BACKSPACE = 8
    KEY_DELETE = 46
    KEY_ALT = 18
    ARROWS = [ VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN ].freeze
    SNAP = 3.0 / 25.4      # drag snaps to guide crossings and the edge middle closer than this
    PICK_APERTURE = 6

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
      UI.set_cursor(JointTool.cursor(_panel_mode? ? 'place' : (@copy ? 'copy' : 'edit')))
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
      elsif _panel_mode?
        @hover = _pick_panel(view, x, y)
        @hover_pair = nil
      else
        @hover = nil
        @hover_pair = _pick_pair(view, x, y)
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      if _panel_mode?
        _panel_click(view, x, y)
      else
        @selected = _pick_pair(view, x, y)
        _start_drag(x, y) if @selected
      end
      _status
      view.invalidate
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
      rows = OclJoints.config[:rows]
      if key == VK_SHIFT
        @shift = true
        handled = false
      elsif key == KEY_ALT
        @alt = true
        @hover_pair = nil
      elsif key == COPY_MODIFIER_KEY
        _toggle_copy unless @ctrl_down || _panel_mode?
        @ctrl_down = true
      elsif ARROWS.include?(key)
        step = [ VK_RIGHT, VK_UP ].include?(key) ? 1 : -1
        horizontal = [ VK_LEFT, VK_RIGHT ].include?(key)
        if @selected && @first.nil?
          if @alt
            _change_selected(edge_step: step)
          elsif @shift
            _change_selected(face_step: step)
          elsif horizontal && !rows.empty?
            current = rows.index { |r| r[:name] == @selected.row } || _row_index
            _change_selected(row_index: (current + step) % rows.length)
          end
        elsif horizontal && !rows.empty?
          OclJoints.row_index = (_row_index + step) % rows.length
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
      if key == KEY_ALT
        @alt = false
        _clear_panels
        _status
        view.invalidate
      end
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
      OclJoints.config[:rows].each_with_index do |row, i|
        item = menu.add_item("#{i + 1}. #{row[:name]}") do
          if @selected
            _change_selected(row_index: i)
          else
            OclJoints.row_index = i
          end
          _status
          view.invalidate
        end
        menu.set_validation_proc(item) { i == _row_index ? MF_CHECKED : MF_ENABLED }
      end
      menu.add_separator
      if @selected
        menu.add_item('Erase pair') { _erase; _status; view.invalidate }
      end
      menu.add_item('Settings...') { OclJoints.show_settings }
      true
    end

    def draw(view)
      if _panel_mode?
        @candidates.each_value { |c| _draw_panel(view, c[:panel], COLOR_CANDIDATE) } if @first
        _draw_panel(view, @first, COLOR_PART) if @first
        _draw_panel(view, @hover, COLOR_PART_HIGHLIGHTED) if @hover && (@first.nil? || @hover.key != @first.key)
      elsif @hover_pair && @hover_pair != @selected
        _draw_pair(view, @hover_pair, COLOR_CANDIDATE, LINE_WIDTH)
      end
      _draw_pair(view, @selected, COLOR_PAIR, LINE_WIDTH) if @selected
      _draw_snap(view) if @drag
    end

    private

    # Panel selection while Alt is held (not during a drag)
    def _panel_mode?
      @alt && @drag.nil?
    end

    def _refresh
      @panels = Scene.panels(@model)
      @panel_by_key = @panels.to_h { |p| [ p.key, p ] }
      @triangles = {}
      @lines = {}
      @features = {}
      @pairs = {}
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
      @candidates = {}
    end

    def _row_index
      OclJoints.row_index.clamp(0, [ OclJoints.config[:rows].length - 1, 0 ].max)
    end

    def _row
      OclJoints.config[:rows][_row_index]
    end

    # --- new pair ---

    def _panel_click(view, x, y)
      panel = _pick_panel(view, x, y)
      if panel.nil?
        _clear_panels
      elsif @first && (candidate = @candidates[panel.key])
        edge_panel, face_panel = candidate[:first_is_edge] ? [ @first, panel ] : [ panel, @first ]
        _add_pair(edge_panel, face_panel, candidate[:contact])
      elsif @first.nil? || panel.key != @first.key
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

    # One pair in the middle of the contact, with the predicted turns; it becomes the selected pair
    def _add_pair(edge_panel, face_panel, contact)
      row = _row
      if row.nil?
        @note = 'The connector table is empty. Open Settings.'
        return
      end
      library = OclJoints.config[:library]
      @model.start_operation('Add joint', true)
      edge_def = Scene.definition(@model, row[:edge], library)
      face_def = Scene.definition(@model, row[:face], library)
      missing = [ [ 'Edge', row[:edge], edge_def ], [ 'Face', row[:face], face_def ] ].reject { |*, d| d }
      unless missing.empty?
        @model.abort_operation
        _clear_panels
        @note = "Component not found: #{missing.map { |_, n, _| "'#{n}'" }.join(', ')}."
        UI.messagebox("Connector '#{row[:name]}': component not found.\n\n" +
                      missing.map { |role, n, _| "#{role} component: '#{n}'" }.join("\n") +
                      "\n\nThe name must be the name of a component definition or instance in the model, " \
                      "or of a .skp file in a library folder (Settings).")
        return
      end

      point = Joint.joint_point(contact, contact.segment.sum / 2.0)
      frames = Joint.frames(contact)
      prediction = Joint.predict(contact, point, edge_panel.box, _features(edge_def),
                                 face_panel.box, _features(face_def), row[:learned])
      ke, kf = prediction[:edge], prediction[:face]
      id = Scene.new_pair_id
      edge = Scene.add(edge_panel, edge_def, Scene.world_transformation(point, frames[:edge], ke), id, 'edge', row[:name], ke)
      face = Scene.add(face_panel, face_def, Scene.world_transformation(point, frames[:face], kf), id, 'face', row[:name], kf)
      @model.commit_operation

      shared = [ edge_panel, face_panel ].map(&:definition).uniq.select { |d| d.instances.length > 1 }
      @note = "Pair added: #{row[:name]}."
      unless shared.empty?
        @note += ' Also in other instances: ' + shared.map { |d| "#{d.name} (#{d.instances.length})" }.join(', ') + '.'
      end
      _clear_panels
      @selected = Scene::Pair.new(id, row[:name], Scene::Part.new(edge_panel, edge), Scene::Part.new(face_panel, face))
    end

    def _features(definition)
      @features[definition] ||= Scene.feature_points(definition)
    end

    # --- selected pair ---

    def _start_drag(x, y)
      contact = _selected_contact
      return if contact.nil?
      guides = Scene.guides(@model, [ @selected.edge.panel, @selected.face.panel ])
      snaps = Joint.positions(contact, guides) + [ contact.segment.sum / 2.0 ]
      l = _selected_l(contact)
      @drag = { contact: contact, l: l, start_l: l, snaps: snaps, moved: false, original: nil, snap_point: nil }
    end

    # Copy on: the moving pair becomes a new copy and the original goes back to the drag start.
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
        [ @selected.edge, @selected.face ].each { |part| part.instance.erase! if part.instance.valid? }
        @selected = original
        @drag[:original] = nil
        _move_pair(original, contact, @drag[:l] - @drag[:start_l])
      end
      @pairs = {}
    end

    # The pair follows the cursor along the edge line. An inference point (end, middle, intersection,
    # guide point, ... as in SketchUp's Move tool) has priority; it is projected onto the edge line.
    # Without it the pair snaps to guide-line crossings and the edge middle.
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

    # Inference on the moving components themselves: not used, it would follow the pair
    def _own_inference?
      entity = @ip.vertex || @ip.edge || @ip.face
      return false if entity.nil?
      parent = entity.is_a?(Sketchup::Vertex) ? entity.edges.first&.parent : entity.parent
      return false unless parent.is_a?(Sketchup::ComponentDefinition)
      own = [ @selected.edge, @selected.face ].flat_map { |part| _definitions(part.instance.definition) }
      own.include?(parent)
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
      Scene.move(pair.edge, vector)
      Scene.move(pair.face, vector)
    end

    def _selected_contact
      Joint.contact(@selected.edge.panel.box, @selected.face.panel.box)
    end

    def _selected_l(contact)
      Joint.dot(Joint.sub(@selected.edge.transformation.origin.to_a, contact.corner), contact.l_axis)
    end

    # Replaces the components of the selected pair (same pair id and position):
    #   row_index:  other connector, turns predicted as for a new pair
    #   edge_step / face_step: next allowed turn of the edge / face component
    def _change_selected(row_index: nil, edge_step: nil, face_step: nil)
      pair = @selected
      contact = _selected_contact
      return if contact.nil?
      rows = OclJoints.config[:rows]
      index = row_index || rows.index { |r| r[:name] == pair.row }
      row = index ? rows[index] : nil
      if row.nil? && row_index.nil?
        # hand-placed pair of components that are not in the table: turn them as they are
        row = { name: pair.row, edge: pair.edge.instance.definition.name, face: pair.face.instance.definition.name }
      end
      library = OclJoints.config[:library]
      edge_panel, face_panel = pair.edge.panel, pair.face.panel
      @model.start_operation('Change joint', true)
      pair = @selected = Scene.link(@selected)
      edge_def = Scene.definition(@model, row[:edge], library)
      face_def = Scene.definition(@model, row[:face], library)
      missing = [ [ row[:edge], edge_def ], [ row[:face], face_def ] ].reject { |_, d| d }.map(&:first)
      unless missing.empty?
        @model.abort_operation
        @note = "Component not found: #{missing.join(', ')}. Add it to the model or to a library folder."
        return
      end

      point = pair.edge.transformation.origin.to_a
      frames = Joint.frames(contact)
      prediction = Joint.predict(contact, point, edge_panel.box, _features(edge_def),
                                 face_panel.box, _features(face_def), row[:learned])
      ke, kf = prediction[:edge], prediction[:face]
      if row_index.nil?
        ke = Scene.turn(pair.edge, frames[:edge])
        kf = Scene.turn(pair.face, frames[:face])
        ke = Joint.next_option(prediction[:edge_options], ke, edge_step) if edge_step
        kf = Joint.next_option(prediction[:face_options], kf, face_step) if face_step
      end

      [ pair.edge, pair.face ].each { |part| part.instance.erase! if part.instance.valid? }
      edge = Scene.add(edge_panel, edge_def, Scene.world_transformation(point, frames[:edge], ke), pair.id, 'edge', row[:name], ke)
      face = Scene.add(face_panel, face_def, Scene.world_transformation(point, frames[:face], kf), pair.id, 'face', row[:name], kf)
      @model.commit_operation

      @selected = Scene::Pair.new(pair.id, row[:name], Scene::Part.new(edge_panel, edge), Scene::Part.new(face_panel, face))
      @hover_pair = nil
      @pairs = {}
      OclJoints.row_index = index if index
      # learn the turns only when the inner side is known: they are relative to it
      if index && row_index.nil? && contact.inner
        config = OclJoints.config
        config[:rows][index] = row.merge(learned: { edge: ke, face: kf })
        OclJoints.save_config(config)
      end
      @note = "Pair: #{row[:name] || 'not in the table'}."
    end

    def _erase
      @model.start_operation('Erase joint', true)
      [ @selected.edge, @selected.face ].each { |part| part.instance.erase! if part.instance.valid? }
      @model.commit_operation
      @pairs = {}
      @selected = nil
      @hover_pair = nil
      @note = 'Pair erased.'
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
          @pairs[key] = pair || Scene.manual_pair(@panels, panel, instance, OclJoints.config[:rows])
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

    def _draw_panel(view, panel, color)
      points = @triangles[panel.key] ||= Scene.triangles(panel.definition).map { |p| p.transform(panel.transformation) }
      return if points.empty?
      view.drawing_color = color
      view.draw(GL_TRIANGLES, points)
    end

    def _draw_pair(view, pair, color, width)
      [ pair.edge, pair.face ].each do |part|
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

    # Inference marker and a dashed line from it to the pair
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
      row = _row
      connector = row ? "Connector #{_row_index + 1}: #{row[:name]}." : 'No connectors.'
      text = if _panel_mode?
               if @first
                 "Select a connected panel (#{@candidates.length} found). Left/Right: connector. Release Alt: cancel."
               else
                 'Select a panel. Left/Right: connector. Release Alt: cancel.'
               end
             elsif @selected
               "Drag: #{@copy ? 'copy' : 'move'} along the edge. Ctrl: copy #{@copy ? 'off' : 'on'}. Left/Right: connector. " \
               'Alt+arrows: turn edge part. Shift+arrows: turn face part. Type a distance from the nearest end. ' \
               'Delete: erase. Hold Alt: new pair. Esc: exit.'
             else
               'Select a pair. Hold Alt and click two panels: new pair. Left/Right: connector. Esc: exit.'
             end
      # the note first: the status bar cuts long texts
      Sketchup.status_text = [ @note, connector, text ].compact.join(' ')
      return unless @selected && (contact = _selected_contact)
      l0, l1 = contact.segment
      l = _selected_l(contact)
      Sketchup.vcb_label = 'Distance'
      Sketchup.vcb_value = Sketchup.format_length([ l - l0, l1 - l ].min)
    end

  end

end
