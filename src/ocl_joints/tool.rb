module OclJoints

  # Interactive tool.
  #   place mode: select a panel, then a connected panel; the tool shows the component pairs,
  #               arrows turn them, Enter or click adds them.
  #   edit mode:  select a placed pair, drag it along the edge or type a distance, Delete erases it.
  #               Ctrl (tap) switches copy on and off, as in SketchUp's Move tool.
  #               The arrow keys change the selected pair as in place mode.
  # Place mode keys: Left / Right select the previous / next connector, Alt + arrows turn the edge
  # component, Shift + arrows turn the face component.
  class JointTool

    # Same colors as OpenCutList's part highlight
    COLOR_PART = Sketchup::Color.new(254, 222, 11, 200)
    COLOR_PART_HIGHLIGHTED = Sketchup::Color.new(254, 222, 11, 255)
    COLOR_CANDIDATE = Sketchup::Color.new(254, 222, 11, 120)
    COLOR_EDGE_PART = Sketchup::Color.new(0, 90, 255)
    COLOR_FACE_PART = Sketchup::Color.new(230, 30, 30)
    COLOR_PAIR = Sketchup::Color.new(255, 140, 0)
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

    def initialize(mode = :place)
      @mode = mode
    end

    def activate
      @model = Sketchup.active_model
      _refresh
      _reset
      @note = @model.active_path ? 'Close the open group or component for correct results.' : nil
      _status
    end

    def onSetCursor
      UI.set_cursor(JointTool.cursor(@mode == :place ? 'place' : (@copy ? 'copy' : 'edit')))
    end

    def deactivate(view)
      view.invalidate
    end

    def resume(view)
      _status
      view.invalidate
    end

    def enableVCB?
      @mode == :edit && !@selected.nil?
    end

    def getExtents
      @model.bounds
    end

    def onCancel(reason, view)
      if reason == 2   # undo: the model changed
        _refresh
        _reset
      elsif @mode == :place && @preview
        @preview = nil
      elsif @mode == :place && @first
        _reset
      else   # edit mode, or nothing selected in place mode
        @model.select_tool(nil)
        return
      end
      _status
      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      # mouse flags have reliable modifier states: they correct a missed key up
      @shift = (flags & CONSTRAIN_MODIFIER_MASK) != 0
      @alt = (flags & ALT_MODIFIER_MASK) != 0
      if @mode == :place
        @hover = @preview ? nil : _pick_panel(view, x, y)
      elsif @drag
        _drag(view, x, y)
      else
        @hover_pair = _pick_pair(view, x, y)
      end
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      if @mode == :place
        _place_click(view, x, y)
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
      _status
      view.invalidate
    end

    def onReturn(view)
      _commit if @mode == :place && @preview
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
        handled = false
      elsif key == COPY_MODIFIER_KEY
        _toggle_copy unless @ctrl_down || @mode != :edit
        @ctrl_down = true
        handled = @mode == :edit
      elsif @mode == :place && ARROWS.include?(key)
        step = [ VK_RIGHT, VK_UP ].include?(key) ? 1 : -1
        if @alt || @shift
          if @preview && @alt
            @preview[:ke] = Joint.next_option(@preview[:edge_options], @preview[:ke], step)
          elsif @preview
            @preview[:kf] = Joint.next_option(@preview[:face_options], @preview[:kf], step)
          end
        elsif [ VK_LEFT, VK_RIGHT ].include?(key) && !rows.empty?
          _select_row((_row_index + step) % rows.length)
        end
      elsif @mode == :edit && @selected && ARROWS.include?(key)
        step = [ VK_RIGHT, VK_UP ].include?(key) ? 1 : -1
        if @alt
          _change_selected(edge_step: step)
        elsif @shift
          _change_selected(face_step: step)
        elsif [ VK_LEFT, VK_RIGHT ].include?(key) && !rows.empty?
          current = rows.index { |r| r[:name] == @selected.row } || _row_index
          _change_selected(row_index: (current + step) % rows.length)
        end
      elsif @mode == :place && (key.between?(49, 57) || key.between?(97, 105)) && (key - 1) % 48 % 9 < rows.length
        _select_row((key - 1) % 48 % 9)
      elsif @mode == :edit && @selected && [ KEY_DELETE, KEY_BACKSPACE ].include?(key)
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
      @alt = false if key == KEY_ALT
      @ctrl_down = false if key == COPY_MODIFIER_KEY
      # Alt is kept too, so its release does not open the menu bar
      ARROWS.include?(key) || key == KEY_ALT || (@mode == :place && (key.between?(49, 57) || key.between?(97, 105)))
    end

    def onUserText(text, view)
      return unless @mode == :edit && @selected
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
        item = menu.add_item("#{i + 1}. #{row[:name]}") { _select_row(i); _status; view.invalidate }
        menu.set_validation_proc(item) { i == _row_index ? MF_CHECKED : MF_ENABLED }
      end
      menu.add_separator
      if @mode == :edit && @selected
        menu.add_item('Erase pair') { _erase; _status; view.invalidate }
      end
      menu.add_item(@mode == :place ? 'Edit mode' : 'Place mode') do
        @mode = @mode == :place ? :edit : :place
        _reset
        _status
        view.invalidate
      end
      menu.add_item('Settings...') { OclJoints.show_settings }
      true
    end

    def draw(view)
      if @mode == :place
        if @first && !@preview
          @candidates.each_value { |c| _draw_panel(view, c[:panel], COLOR_CANDIDATE) }
        end
        _draw_panel(view, @first, COLOR_PART) if @first
        if @preview
          other = @preview[:edge_panel].key == @first.key ? @preview[:face_panel] : @preview[:edge_panel]
          _draw_panel(view, other, COLOR_PART)
          _draw_preview(view)
        elsif @hover && (@first.nil? || @hover.key != @first.key)
          _draw_panel(view, @hover, COLOR_PART_HIGHLIGHTED)
        end
      else
        _draw_pair(view, @hover_pair, COLOR_CANDIDATE, LINE_WIDTH) if @hover_pair && @hover_pair != @selected
        _draw_pair(view, @selected, COLOR_PAIR, LINE_WIDTH) if @selected
      end
    end

    private

    def _refresh
      @panels = Scene.panels(@model)
      @panel_by_key = @panels.to_h { |p| [ p.key, p ] }
      @triangles = {}
      @lines = {}
      @features = {}
      @pairs = {}
    end

    def _reset
      @hover = nil
      @first = nil
      @candidates = {}
      @preview = nil
      @hover_pair = nil
      @selected = nil
      @drag = nil
      @copy = false
    end

    def _row_index
      OclJoints.row_index.clamp(0, [ OclJoints.config[:rows].length - 1, 0 ].max)
    end

    def _row
      OclJoints.config[:rows][_row_index]
    end

    def _select_row(i)
      OclJoints.row_index = i
      _build_preview(@preview[:edge_panel], @preview[:face_panel], @preview[:contact]) if @preview
    end

    # --- place mode ---

    def _place_click(view, x, y)
      return _commit if @preview
      panel = _pick_panel(view, x, y)
      if panel.nil?
        _reset
      elsif @first && (candidate = @candidates[panel.key])
        edge_panel, face_panel = candidate[:first_is_edge] ? [ @first, panel ] : [ panel, @first ]
        _build_preview(edge_panel, face_panel, candidate[:contact])
      elsif @first.nil? || panel.key != @first.key
        _set_first(panel)
      end
    end

    def _set_first(panel)
      _reset
      @first = panel
      @panels.each do |p|
        next if p.key == panel.key
        contact, first_is_edge = Joint.joint(panel.box, p.box)
        @candidates[p.key] = { panel: p, contact: contact, first_is_edge: first_is_edge } if contact
      end
    end

    def _build_preview(edge_panel, face_panel, contact)
      @preview = nil
      row = _row
      if row.nil?
        @note = 'The connector table is empty. Open Settings.'
        return
      end
      library = OclJoints.config[:library]
      @model.start_operation('Load joint components', true)
      edge_def = Scene.definition(@model, row[:edge], library)
      face_def = Scene.definition(@model, row[:face], library)
      @model.commit_operation
      missing = [ [ row[:edge], edge_def ], [ row[:face], face_def ] ].reject { |_, d| d }.map(&:first)
      unless missing.empty?
        @note = "Component not found: #{missing.join(', ')}. Add it to the model or to a library folder."
        return
      end

      positions = Joint.positions(contact, Scene.guides(@model, [ edge_panel, face_panel ]))
      points = positions.map { |l| Joint.joint_point(contact, l) }
      prediction = Joint.predict(contact, points.first, edge_panel.box, _features(edge_def),
                                 face_panel.box, _features(face_def), row[:learned])
      @preview = { edge_panel: edge_panel, face_panel: face_panel, contact: contact, points: points,
                   edge_def: edge_def, face_def: face_def, frames: Joint.frames(contact),
                   ke: prediction[:edge], kf: prediction[:face],
                   edge_options: prediction[:edge_options], face_options: prediction[:face_options] }
      @note = nil
    end

    def _commit
      p = @preview
      row = _row
      @model.start_operation('Add joints', true)
      pairs = p[:points].map do |point|
        id = Scene.new_pair_id
        edge = Scene.add(p[:edge_panel], p[:edge_def], Scene.world_transformation(point, p[:frames][:edge], p[:ke]), id, 'edge', row[:name], p[:ke])
        face = Scene.add(p[:face_panel], p[:face_def], Scene.world_transformation(point, p[:frames][:face], p[:kf]), id, 'face', row[:name], p[:kf])
        Scene::Pair.new(id, row[:name], Scene::Part.new(p[:edge_panel], edge), Scene::Part.new(p[:face_panel], face))
      end
      @model.commit_operation

      # learn the turns only when the inner side is known: they are relative to it
      if p[:contact].inner
        config = OclJoints.config
        config[:rows][_row_index] = row.merge(learned: { edge: p[:ke], face: p[:kf] })
        OclJoints.save_config(config)
      end

      shared = [ p[:edge_panel], p[:face_panel] ].map(&:definition).uniq.select { |d| d.instances.length > 1 }
      @note = "#{p[:points].length} pair(s) added."
      unless shared.empty?
        @note += ' Also in other instances: ' + shared.map { |d| "#{d.name} (#{d.instances.length})" }.join(', ') + '.'
      end
      # edit mode with the last pair selected: move it or erase it immediately
      _reset
      @mode = :edit
      @selected = pairs.last
    end

    def _features(definition)
      @features[definition] ||= Scene.feature_points(definition)
    end

    # --- edit mode ---

    def _start_drag(x, y)
      contact = _selected_contact
      return if contact.nil?
      guides = Scene.guides(@model, [ @selected.edge.panel, @selected.face.panel ])
      snaps = Joint.positions(contact, guides) + [ contact.segment.sum / 2.0 ]
      l = _selected_l(contact)
      @drag = { contact: contact, l: l, start_l: l, snaps: snaps, moved: false, original: nil }
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

    def _drag(view, x, y)
      contact = @drag[:contact]
      ray = view.pickray(x, y)
      l = Joint.nearest_l(contact, ray[0].to_a, ray[1].to_a).clamp(*contact.segment)
      snap = @drag[:snaps].min_by { |s| (s - l).abs }
      l = snap if snap && (snap - l).abs < SNAP
      delta = l - @drag[:l]
      return if delta.abs < 1e-6
      unless @drag[:moved]
        @model.start_operation(@copy ? 'Copy joint' : 'Move joint', true)
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
    #   row_index:  other connector, turns predicted as in place mode
    #   edge_step / face_step: next allowed turn of the edge / face component
    def _change_selected(row_index: nil, edge_step: nil, face_step: nil)
      pair = @selected
      contact = _selected_contact
      return if contact.nil?
      rows = OclJoints.config[:rows]
      index = row_index || rows.index { |r| r[:name] == pair.row }
      row = index ? rows[index] : nil
      if row.nil?
        @note = "Connector '#{pair.row}' is not in the table."
        return
      end
      library = OclJoints.config[:library]
      edge_panel, face_panel = pair.edge.panel, pair.face.panel
      @model.start_operation('Change joint', true)
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
      OclJoints.row_index = index
      if row_index.nil? && contact.inner
        config = OclJoints.config
        config[:rows][index] = row.merge(learned: { edge: ke, face: kf })
        OclJoints.save_config(config)
      end
      @note = "Pair: #{row[:name]}."
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
        j = full.index { |e| e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(Scene::DICTIONARY, 'pair_id') }
        next if j.nil?
        panel = @panel_by_key[full[0...j].map(&:entityID).join('/')]
        next if panel.nil?
        key = "#{panel.key}/#{full[j].entityID}"
        @pairs[key] = Scene.pair(@panels, panel, full[j]) unless @pairs.key?(key)
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

    # Preview components are inside the panels, so they are drawn over the model (2D)
    def _draw_preview(view)
      p = @preview
      p[:points].each do |point|
        _draw_component(view, p[:edge_def], Scene.world_transformation(point, p[:frames][:edge], p[:ke]), COLOR_EDGE_PART, LINE_WIDTH)
        _draw_component(view, p[:face_def], Scene.world_transformation(point, p[:frames][:face], p[:kf]), COLOR_FACE_PART, LINE_WIDTH)
      end
      view.draw_points(p[:points].map { |pt| Geom::Point3d.new(*pt) }, 8, 3, COLOR_PART_HIGHLIGHTED)
    end

    def _draw_pair(view, pair, color, width)
      [ pair.edge, pair.face ].each do |part|
        next unless part.instance.valid?
        _draw_component(view, part.instance.definition, part.transformation, color, width)
      end
    end

    def _draw_component(view, definition, transformation, color, width)
      points = @lines[definition] ||= Scene.lines(definition)
      return if points.empty?
      view.line_width = width
      view.drawing_color = color
      view.draw2d(GL_LINES, points.map { |pt| view.screen_coords(pt.transform(transformation)) })
    end

    # --- status bar ---

    def _status
      row = _row
      connector = row ? "Connector #{_row_index + 1}: #{row[:name]}." : 'No connectors.'
      text = if @mode == :place
               if @preview
                 "#{@preview[:points].length} pair(s). Left/Right: connector. Alt+arrows: turn edge part. Shift+arrows: turn face part. Enter or click: add. Esc: cancel."
               elsif @first
                 "Select a connected panel (#{@candidates.length} found). Left/Right: connector. Esc: cancel."
               else
                 'Select a panel. Left/Right or keys 1-9: connector.'
               end
             elsif @selected
               "Drag: #{@copy ? 'copy' : 'move'} along the edge. Ctrl: copy #{@copy ? 'off' : 'on'}. Left/Right: connector. Alt+arrows: turn edge part. Shift+arrows: turn face part. Type a distance from the nearest end. Delete: erase. Esc: exit."
             else
               "Select a placed pair. Ctrl: copy #{@copy ? 'off' : 'on'}. Esc: exit."
             end
      Sketchup.status_text = [ connector, text, @note ].compact.join(' ')
      return unless @mode == :edit && @selected && (contact = _selected_contact)
      l0, l1 = contact.segment
      l = _selected_l(contact)
      Sketchup.vcb_label = 'Distance'
      Sketchup.vcb_value = Sketchup.format_length([ l - l0, l1 - l ].min)
    end

  end

end
