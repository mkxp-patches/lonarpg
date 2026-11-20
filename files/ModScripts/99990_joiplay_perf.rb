# LonaRPG JoiPlay Performance & Compatibility Patch (Ruby 1.9.2 / libmkxp19.so)
# Loads in ModScripts/ right before Main.rb. Reversible: delete this file to revert.

begin
  module ::JPPerf
    LOG_ENABLED = false
    LOG_PATH = "joiplay_verify.log"
    EMPTY_STR = ""
    CHAR_TAG = "-char-"

    def self.is_mkxp?
      (defined?($MKXP) && $MKXP) || defined?(::MKXP)
    end

    def self.log(msg)
      return if defined?(::Thread) && ::Thread.current != ::Thread.main
      if LOG_ENABLED
        ::MKXP.puts("[PERF] " + msg.to_s) if defined?(::MKXP) && ::MKXP.respond_to?(:puts)
        return if @file_err
        begin
          @file ||= ::File.open(LOG_PATH, "a")
          t = ::Time.now
          ts = sprintf("%s.%03d", t.strftime("%H:%M:%S"), (t.usec / 1000))
          @file.write("[#{ts}] #{msg}\n")
          @file.flush
        rescue Exception => e
          @file_err = true
          ::MKXP.puts("[PERF FILE ERR] #{e.class}: #{e.message}") if defined?(::MKXP) && ::MKXP.respond_to?(:puts)
        end
      elsif msg.to_s.include?("ERR")
        ::MKXP.puts("[PERF] " + msg.to_s) if defined?(::MKXP) && ::MKXP.respond_to?(:puts)
      end
    end
  end

  is_mkxp = ::JPPerf.is_mkxp?

  # ---------------------------------------------------------------------------
  # Patch 1: Crash-proof Save System (Cache.savefile_bitmap + make_save_screenshot)
  # ---------------------------------------------------------------------------
  begin
    if defined?(::Cache)
      module ::Cache
        class << self
          if method_defined?(:savefile_bitmap)
            def savefile_bitmap(path)
              @cache_savefile_bitmap ||= {}
              bmp = @cache_savefile_bitmap[path]
              return bmp if bmp && !bmp.disposed?
              begin
                bmp = ::Bitmap.new(path)
              rescue Exception
                fallback = "Graphics/System/SaveNotFound.png"
                fbmp = @cache_savefile_bitmap[fallback]
                if fbmp && !fbmp.disposed?
                  bmp = fbmp
                else
                  begin
                    bmp = ::Bitmap.new(fallback)
                    @cache_savefile_bitmap[fallback] = bmp
                  rescue Exception
                    bmp = ::Bitmap.new(264, 160)
                  end
                end
              end
              @cache_savefile_bitmap[path] = bmp
            end
          end
        end
      end
    end

    if is_mkxp && defined?(::DataManager)
      module ::DataManager
        class << self
          if method_defined?(:make_save_screenshot)
            def make_save_screenshot(index)
            end
          end
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch1 Save] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 2: Disable dead Windows x86 hooks on JoiPlay
  # ---------------------------------------------------------------------------
  begin
    if is_mkxp
      if defined?(::Bitmap)
        class ::Bitmap
          if method_defined?(:initialize_pre_failsafe) || private_method_defined?(:initialize_pre_failsafe)
            alias initialize initialize_pre_failsafe
          end
        end
      end

      if defined?(::BitmapChanger)
        module ::BitmapChanger
          class << self
            if method_defined?(:load_settings)
              def load_settings(*args)
                @filters = {}
                @name_to_setting = {}
              end
            end

            if method_defined?(:find_cache_name)
              def find_cache_name(filename)
                ::JPPerf::EMPTY_STR
              end
            end

            if method_defined?(:change_bitmap)
              def change_bitmap(bitmap, filename)
                bitmap
              end
            end
          end
        end
      end

      if defined?(::WolfPad)
        module ::WolfPad
          class << self
            if method_defined?(:update)
              def update(*args)
              end
            end
          end
        end
      end

      if defined?(::Shadow)
        class ::Shadow
          def draw(*args); end if method_defined?(:draw)
          def clear(*args); end if method_defined?(:clear)
          def draw_lights(*args); end if method_defined?(:draw_lights)
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch2 Win32Bypass] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 3: Zero-allocation Sprite_Character & single-pass Spriteset_Map
  # ---------------------------------------------------------------------------
  begin
    if defined?(::Sprite_Character)
      class ::Sprite_Character
        if method_defined?(:update_bitmap)
          alias jpopt_update_bitmap update_bitmap
          def update_bitmap(*args)
            @jp_sr_valid = false if graphic_changed?
            jpopt_update_bitmap(*args)
          end
        end

        def update
          return if @character.nil?
          @sx = @character.screen_x
          @sy = @character.screen_y
          if !need_update?
            if @jp_vis != false
              self.visible = false
              @jp_vis = false
            end
            return
          end
          super
          update_bitmap
          update_src_rect
          update_position
          update_other
          update_balloon
          update_tone
          setup_new_effect
        end

        def need_update?
          return true if graphic_changed?
          return true if @character.animation_id > 0
          return true if @balloon_sprite
          return true if @character.balloon_id != 0
          cw = @cw || 32
          ch = @ch || 32
          @sx >= -cw && @sx <= (::Graphics.width + cw) && @sy >= 0 && @sy <= (::Graphics.height + ch)
        end

        def update_tone
          t = @character.tone
          if t.nil?
            return if @jp_tone_zero
            self.tone.set(0, 0, 0, 0)
            @jp_tone_zero = true
            @jp_tr = nil
            @jp_tg = nil
            @jp_tb = nil
            @jp_tgr = nil
            return
          end
          r = t.red
          g = t.green
          b = t.blue
          gr = t.gray
          return if !@jp_tone_zero && @jp_tr == r && @jp_tg == g && @jp_tb == b && @jp_tgr == gr
          self.tone.set(r, g, b, gr)
          @jp_tone_zero = false
          @jp_tr = r
          @jp_tg = g
          @jp_tb = b
          @jp_tgr = gr
        end

        def update_src_rect
          ch = @character
          if ch.animation
            @jp_sr_valid = false
            cell_x, cell_y, duration = ch.animation.frame_data
            self.src_rect.set(cell_x * @cw, cell_y * @ch, @cw, @ch)
          elsif @tile_id == 0
            index = ch.character_index
            pat = ch.pattern
            pattern = pat < 3 ? pat : 1
            dir = ch.direction
            cw = @cw
            c_h = @ch
            return if @jp_sr_valid && @jp_sr_idx == index && @jp_sr_pat == pattern && @jp_sr_dir == dir && @jp_sr_cw == cw && @jp_sr_ch == c_h
            sx = (index % 4 * 3 + pattern) * cw
            sy = (index / 4 * 4 + (dir - 2) / 2) * c_h
            ch.char_block_height = c_h
            ch.char_block_width = cw
            self.src_rect.set(sx, sy, cw, c_h)
            @jp_sr_valid = true
            @jp_sr_idx = index
            @jp_sr_pat = pattern
            @jp_sr_dir = dir
            @jp_sr_cw = cw
            @jp_sr_ch = c_h
          end
        end

        def update_position
          ch = @character
          nx = @sx
          ny = @sy
          nz = ch.screen_z
          if anim = ch.animation
            fd = anim.frame_data
            nx += (fd[3] || 0)
            ny += (fd[4] || 0)
          end
          if @jp_x != nx
            self.x = nx
            @jp_x = nx
          end
          if @jp_y != ny
            self.y = ny
            @jp_y = ny
          end
          if @jp_z != nz
            self.z = nz
            @jp_z = nz
          end
        end

        def update_other
          ch = @character
          op = ch.opacity
          if @jp_op != op
            self.opacity = op
            @jp_op = op
          end
          bt = ch.blend_type
          if @jp_bt != bt
            self.blend_type = bt
            @jp_bt = bt
          end
          bd = ch.bush_depth
          if @jp_bd != bd
            self.bush_depth = bd
            @jp_bd = bd
          end
          vis = !ch.transparent
          if @jp_vis != vis
            self.visible = vis
            @jp_vis = vis
          end
          zx = ch.zoom_x
          if @jp_zx != zx
            self.zoom_x = zx
            @jp_zx = zx
          end
          zy = ch.zoom_y
          if @jp_zy != zy
            self.zoom_y = zy
            @jp_zy = zy
          end
          mir = ch.mirror
          if @jp_mir != mir
            self.mirror = mir
            @jp_mir = mir
          end
          ang = ch.angle
          if @jp_ang != ang
            self.angle = ang
            @jp_ang = ang
          end
        end
      end
    end

    if defined?(::Spriteset_Map) && ::Spriteset_Map.method_defined?(:update_characters)
      class ::Spriteset_Map
        def update_characters
          refresh_characters if @map_id != $game_map.map_id || $ov
          append_character if $game_map.added_ev_ids.length > 0
          need_compact = false
          @character_sprites.each do |sprite|
            if sprite.disposed?
              need_compact = true
            else
              ch = sprite.character
              if ch.nil? || ch.deleted?
                sprite.dispose
                need_compact = true
              else
                sprite.update
              end
            end
          end
          @character_sprites.reject! { |sprite| sprite.disposed? } if need_compact
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch3 Sprites] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 4: Zero-allocation Game_Map#update_events, Game_Event, Game_CharacterBase
  # ---------------------------------------------------------------------------
  begin
    if defined?(::Game_Map) && ::Game_Map.method_defined?(:update_events)
      class ::Game_Map
        def update_events
          del = (@jp_del_keys ||= [])
          del.clear
          @events.each do |key, event|
            next if event.nil? || event.backgroundEvent
            if event.deleted?
              @npc_changed = true if event.npc?
              if event.foreign_event || !event.nappable? || !event.reset_strong
                del << key
              end
            end
          end
          unless del.empty?
            del.each do |key|
              ev = @events[key]
              delete_event_from_pos_hash(ev)
              delete_npc(ev) if ev.npc
              @events[key] = nil
              @events.delete(key)
            end
            del.clear
          end
          @events.each_value do |event|
            next if event.backgroundEvent
            event.update
          end
          @common_events.each { |event| event.update }
          summon_event(*@summoned_evs.shift) until @summoned_evs.empty?
        end
      end
    end

    if defined?(::Game_Event)
      class ::Game_Event
        def update
          return if ($game_map.interpreter.running? || $game_pause) && !@force_update
          update_npc if @npc
          super
          tmp_npc_disabled = @npc.nil? ? false : npc_disabled?
          unless tmp_npc_disabled
            check_event_trigger_auto
            check_event_trigger_region
          end
          check_event_trigger_over(self.x, self.y) if !tmp_npc_disabled || @over_trigger == 1
          update_animation_synced
          return unless @interpreter
          @interpreter.setup(@list, @event.id) unless @interpreter.running?
          @interpreter.update
        end

        def check_event_trigger_region
          return unless @region_trigger && (@trigger == 1 || @trigger == 2)
          return if $game_map.interpreter.running?
          start if @region_trigger == $game_map.region_id($game_player.x, $game_player.y)
        end

        def npc_disabled?
          return false if @npc.nil? || @force_NpcAbleTrigger
          return false if $game_map.isOverMap
          st = @npc.action_state
          return true if st == :stun || st == :sex
          ais = @npc.ai_state
          return false if (normal_move_type? && !@npc.target) || ais.nil? || ais == :none
          true
        end

        def current_page_charset?
          pg = @page
          return false if pg.nil?
          cname = pg.graphic.character_name
          return @jp_chs_val if pg.equal?(@jp_chs_page) && cname.equal?(@jp_chs_cname)
          @jp_chs_page = pg
          @jp_chs_cname = cname
          @jp_chs_val = cname.include?(::JPPerf::CHAR_TAG)
        end
      end
    end

    if defined?(::Game_CharacterBase) && ::Game_CharacterBase.method_defined?(:update_character_ex_effects)
      class ::Game_CharacterBase
        alias jpopt_update_character_ex_effects update_character_ex_effects
        def update_character_ex_effects(*args)
          return if @erased || @effects.nil?
          e0 = @effects[0]
          return if e0.nil? || e0.empty?
          jpopt_update_character_ex_effects(*args)
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch4 Events] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 5: Zero-allocation Game_Map tile/passage lookups & Sensor memoization
  # ---------------------------------------------------------------------------
  begin
    if defined?(::Game_Map)
      class ::Game_Map
        def spec_dir_blocker_passable?(x, y, d)
          return false if @forced_block_dir.empty?
          @forced_block_dir.include?([x, y, d])
        end

        def check_passage(x, y, bit)
          flags = tileset.flags
          unless @tile_events.empty?
            @tile_events.each do |ev|
              next unless ev.pos_nt?(x, y)
              flag = flags[ev.tile_id]
              next if (flag & 0x10) != 0
              return true  if (flag & bit) == 0
              return false if (flag & bit) == bit
            end
          end
          data = @map.data
          z = 2
          while z >= 0
            flag = flags[data[x, y, z] || 0]
            if (flag & 0x10) == 0
              return true  if (flag & bit) == 0
              return false if (flag & bit) == bit
            end
            z -= 1
          end
          false
        end

        def layered_tiles_flag?(x, y, bit)
          flags = tileset.flags
          data = @map.data
          z = 2
          while z >= 0
            return true if (flags[data[x, y, z] || 0] & bit) != 0
            z -= 1
          end
          false
        end

        def get_event_terrain_tag(x, y)
          evs = events_xy(x, y)
          return nil if evs.empty?
          evs.each do |ev|
            t = ev.ev_terrain_tag
            return t if t
          end
          nil
        end

        def terrain_tag(x, y)
          return 0 unless valid?(x, y)
          ev_tt = get_event_terrain_tag(x, y)
          return ev_tt unless ev_tt.nil?
          flags = tileset.flags
          data = @map.data
          z = 2
          while z >= 0
            tag = flags[data[x, y, z] || 0] >> 12
            return tag if tag > 0
            z -= 1
          end
          0
        end
      end
    end

    if defined?(::Sensors) && defined?(::Sensors::Basic_Sensor)
      ::ObjectSpace.each_object(::Class) do |k|
        next unless k < ::Sensors::Basic_Sensor
        sc = class << k; self; end
        own = sc.instance_methods(false)
        next unless own.include?(:detection_array) || own.include?("detection_array")
        alias_sym = :"jpopt_det_#{k.object_id}"
        next if own.include?(alias_sym) || own.include?(alias_sym.to_s)
        sc.class_eval do
          alias_method alias_sym, :detection_array
          define_method(:detection_array) do
            @jp_det_arr ||= __send__(alias_sym)
          end
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch5 MapSensors] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 6: Map_Hud allocation fixes & snappier Scene_Base transitions
  # ---------------------------------------------------------------------------
  begin
    if defined?(::Map_Hud)
      class ::Map_Hud
        if method_defined?(:refresh_face)
          def refresh_face
            index = @dmg_timer > 0 ? 0 : [(@actor.mood + 100).to_i / 25, 3].min
            w = @face.bitmap.width / 8
            tar_x = w * (3 - index)
            return if @face.src_rect.x == tar_x
            @face.src_rect.set(tar_x, 0, w, @face.height)
          end
        end

        if method_defined?(:refresh_mood_meter)
          def refresh_mood_meter
            index = [(@actor.mood).to_i / 25, 3].min
            w = 3
            tar_x = w * (3 - index)
            bh = @mood_meter.bitmap.height
            tar_h = ((@actor.mood % 25) / 25.0 * bh).ceil
            tar_h = bh if @actor.mood == 100
            tar_h = 1 if tar_h == 0 && @actor.mood != 0
            return if @mood_meter.src_rect.x == tar_x && @mood_meter.src_rect.height == tar_h
            @mood_meter.src_rect.set(tar_x, bh - tar_h, w, tar_h)
            @mood_meter.y = 37 - tar_h
            @mood_meter_back.src_rect.x = tar_x + w * 5
          end
        end

        if method_defined?(:refresh_exp_meter)
          alias jpopt_refresh_exp_meter refresh_exp_meter
          def refresh_exp_meter(*args)
            exp = @actor.exp
            lvl = @actor.level
            return if @jp_exp == exp && @jp_lvl == lvl
            @jp_exp = exp
            @jp_lvl = lvl
            jpopt_refresh_exp_meter(*args)
          end
        end
      end
    end

    if defined?(::Scene_Base) && ::Scene_Base.method_defined?(:transition_speed)
      class ::Scene_Base
        def transition_speed
          4
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch6 HudFade] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 7: Map-transfer GC (keeps GC pauses out of active gameplay)
  # ---------------------------------------------------------------------------
  begin
    if defined?(::Scene_Map) && ::Scene_Map.method_defined?(:perform_transfer)
      class ::Scene_Map
        alias jpopt_perform_transfer perform_transfer
        def perform_transfer(*args)
          r = jpopt_perform_transfer(*args)
          ::GC.start
          r
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch7 TransferGC] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 8: Fast C-Regex JSON.decode
  # ---------------------------------------------------------------------------
  begin
    module ::JPFastJSON
      TOKEN_RE = /"[^"]*"|\/\/[^\n]*|-?(?:\d+(?:\.\d+)?|\.\d+)|\btrue\b|\bfalse\b|\bnull\b|[\{\}\[\]:,]/

      def self.decode(str)
        return nil if str.nil?
        toks = str.scan(TOKEN_RE)
        @toks = toks
        @n = toks.length
        @i = 0
        val = parse_val
        @toks = nil
        val
      end

      def self.next_tok
        while @i < @n
          t = @toks[@i]
          @i += 1
          return t if t.getbyte(0) != 47
        end
        nil
      end

      def self.parse_val
        t = next_tok
        return nil if t.nil?
        parse_from_tok(t)
      end

      def self.parse_from_tok(t)
        b = t.getbyte(0)
        if b == 34
          return t.slice(1, t.length - 2)
        elsif b == 123
          obj = {}
          while (tk = next_tok)
            tb = tk.getbyte(0)
            break if tb == 125
            next if tb == 44
            key = (tb == 34) ? tk.slice(1, tk.length - 2) : tk
            sep = next_tok
            break if sep.nil?
            if sep.getbyte(0) == 58
              obj[key] = parse_val
            else
              obj[key] = parse_from_tok(sep)
            end
          end
          return obj
        elsif b == 91
          arr = []
          while (tk = next_tok)
            tb = tk.getbyte(0)
            break if tb == 93
            next if tb == 44
            arr << parse_from_tok(tk)
          end
          return arr
        elsif t == "true"
          return true
        elsif t == "false"
          return false
        elsif t == "null"
          return nil
        else
          return t.include?(".") ? t.to_f : t.to_i
        end
      end
    end

    if defined?(::JSON)
      module ::JSON
        class << self
          if method_defined?(:decode)
            alias jpopt_orig_decode decode
            def decode(json)
              ::JPFastJSON.decode(json)
            rescue Exception
              jpopt_orig_decode(json)
            end
          end
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch8 FastJSON] #{e.class}: #{e.message}")
  end

  # ---------------------------------------------------------------------------
  # Patch 9: Self-Validating Unified Marshal Boot Cache (Data/jp_boot_cache.rvdata2)
  # ---------------------------------------------------------------------------
  begin
    module ::JPBootCache
      CACHE_PATH = "Data/jp_boot_cache.rvdata2"
      CACHE_TMP  = "Data/jp_boot_cache.rvdata2.tmp"

      @capturing = false
      @captured_npc_portraits = nil

      def self.capturing
        @capturing
      end

      def self.capturing=(v)
        @capturing = v
      end

      def self.captured_npc_portraits
        @captured_npc_portraits
      end

      def self.captured_npc_portraits=(v)
        @captured_npc_portraits = v
      end

      def self.fingerprint
        ver = (::DataManager.export_full_ver_info rescue "unknown").to_s
        mods_cfg = (::File.open("UserData/GameMods.ini", "rb") { |f| f.read } rescue "")
        mod_dirs = (::Dir["ModScripts/_Mods/*"].sort rescue [])
        sys_sz = (::File.size("Data/System.rvdata2") rescue 0)
        [2, ver, mods_cfg, mod_dirs, sys_sz]
      end

      def self.try_restore(fp)
        return false unless ::File.file?(CACHE_PATH)
        data = nil
        begin
          data = ::File.open(CACHE_PATH, "rb") { |f| ::Marshal.load(f) }
        rescue Exception => e
          ::JPPerf.log("[BOOT_CACHE LOAD ERR] #{e.class}: #{e.message}")
          return false
        end
        if !data.is_a?(::Hash)
          ::JPPerf.log("BOOT_CACHE invalid payload class=#{data.class}")
          return false
        end
        if data[:fp] != fp
          ::JPPerf.log("BOOT_CACHE fp mismatch: cached=#{data[:fp].inspect} cur=#{fp.inspect}")
          return false
        end
        unless data[:npc_portrait_hashes].is_a?(::Array)
          ::JPPerf.log("BOOT_CACHE missing npc_portrait_hashes")
          return false
        end

        $data_actors         = data[:data_actors]
        $data_classes        = data[:data_classes]
        $data_skills         = data[:data_skills]
        $data_weapons        = data[:data_weapons]
        $data_armors         = data[:data_armors]
        $data_states         = data[:data_states]
        $data_items          = data[:data_items]
        $data_itemconfigs    = data[:data_itemconfigs]
        $data_tilesets       = data[:data_tilesets]
        $data_common_events  = data[:data_common_events]
        $data_common_parallel = data[:data_common_parallel]
        $data_common_auto    = data[:data_common_auto]
        $data_system         = data[:data_system]
        $data_mapinfos       = data[:data_mapinfos]
        $data_LonaMood       = data[:data_LonaMood]
        $data_SkillName      = data[:data_SkillName]
        $data_ItemName       = data[:data_ItemName]
        $data_StateName      = data[:data_StateName]
        $chs_data            = data[:chs_data]
        $data_npcs           = data[:data_npcs]
        $data_tag_maps       = data[:data_tag_maps]
        $data_region_maps    = data[:data_region_maps]
        $data_arpgskills     = data[:data_arpgskills]
        $data_EventLib       = data[:data_EventLib]
        $data_barters        = data[:data_barters]
        $data_AlchemyRecipes = data[:data_AlchemyRecipes]
        $data_lona_portrait  = data[:data_lona_portrait]

        if data[:lona_canvas].is_a?(::Hash) && defined?(::System_Settings::LONA_PORTRAIT_CANVAS_SETTING)
          ::System_Settings::LONA_PORTRAIT_CANVAS_SETTING.clear
          data[:lona_canvas].each do |k, v|
            ::System_Settings::LONA_PORTRAIT_CANVAS_SETTING[k] = v
          end
        end

        $data_npc_portraits = data[:npc_portrait_hashes].map { |h| ::NPC_Portrait.fromHash(h) }
        true
      rescue Exception => e
        ::JPPerf.log("[BOOT_CACHE RESTORE ERR] #{e.class}: #{e.message}")
        false
      end

      def self.save_cache(fp)
        return false unless @captured_npc_portraits.is_a?(::Array) && !@captured_npc_portraits.empty?
        t_s0 = ::Time.now.to_f
        payload = {
          :fp => fp,
          :data_actors => $data_actors,
          :data_classes => $data_classes,
          :data_skills => $data_skills,
          :data_weapons => $data_weapons,
          :data_armors => $data_armors,
          :data_states => $data_states,
          :data_items => $data_items,
          :data_itemconfigs => $data_itemconfigs,
          :data_tilesets => $data_tilesets,
          :data_common_events => $data_common_events,
          :data_common_parallel => $data_common_parallel,
          :data_common_auto => $data_common_auto,
          :data_system => $data_system,
          :data_mapinfos => $data_mapinfos,
          :data_LonaMood => $data_LonaMood,
          :data_SkillName => $data_SkillName,
          :data_ItemName => $data_ItemName,
          :data_StateName => $data_StateName,
          :chs_data => $chs_data,
          :data_npcs => $data_npcs,
          :data_tag_maps => $data_tag_maps,
          :data_region_maps => $data_region_maps,
          :data_arpgskills => $data_arpgskills,
          :data_EventLib => $data_EventLib,
          :data_barters => $data_barters,
          :data_AlchemyRecipes => $data_AlchemyRecipes,
          :data_lona_portrait => $data_lona_portrait,
          :lona_canvas => defined?(::System_Settings::LONA_PORTRAIT_CANVAS_SETTING) ? ::System_Settings::LONA_PORTRAIT_CANVAS_SETTING : {},
          :npc_portrait_hashes => @captured_npc_portraits
        }
        ::File.open(CACHE_TMP, "wb") { |f| ::Marshal.dump(payload, f) }
        ::File.rename(CACHE_TMP, CACHE_PATH)
        t_save = ::Time.now.to_f - t_s0
        sz_kb = (::File.size(CACHE_PATH) / 1024 rescue 0)
        [t_save, sz_kb]
      rescue Exception => e
        ::JPPerf.log("[BOOT_CACHE SAVE ERR] #{e.class}: #{e.message}")
        nil
      end
    end

    if defined?(::FileGetter)
      module ::FileGetter
        class << self
          if method_defined?(:load_npc_portraits_dir)
            alias jpopt_load_npc_portraits_dir load_npc_portraits_dir
            def load_npc_portraits_dir(folder = "Data/Pconfig/Pconfig_npc/")
              if folder == "Data/Pconfig/Pconfig_npc/" && ::JPBootCache.capturing
                npc_portraits = []
                file_list = getFileList("#{folder}*.json")
                npc_datas = []
                file_list.each do |file_dir|
                  raw = ::File.open(file_dir, "r") { |f| f.read }
                  npc_data = ::JSON.decode(remove_json_comments(raw))
                  npc_datas << npc_data
                  npc_portraits << ::NPC_Portrait.fromHash(npc_data)
                end
                ::JPBootCache.captured_npc_portraits = npc_datas
                save_data(npc_datas, "Data/npc_portraits.rvdata2") if ::FileGetter::WRITING_LIST
                return npc_portraits
              end
              jpopt_load_npc_portraits_dir(folder)
            end
          end
        end
      end
    end

    if defined?(::DataManager)
      module ::DataManager
        class << self
          if method_defined?(:load_normal_database)
            alias jpopt_load_normal_database load_normal_database
            def load_normal_database(*args)
              t0 = ::Time.now.to_f
              fp = ::JPBootCache.fingerprint
              if ::JPBootCache.try_restore(fp)
                $data_BGMvol        = get_vol_constant("BGMvol")
                $data_SNDvol        = get_vol_constant("SNDvol")
                $data_PrtFocusMode  = get_constant("LonaRPG", "PrtFocusMode", 1)
                $data_ToneMode      = get_map_background_color_constant
                $data_GamePadUImode = get_text_constant("LonaRPG", "GamePadUImode", 16)
                $loading_screen.update("Init MODS") if $loading_screen
                load_mod_database
                ::InputUtils.update_padSYM_in_UI
                if $LonaINI && $LonaINI["Cache"]
                  cc = $LonaINI["Cache"]
                  ::Cache.precache_lona_prt_bitmap("pose") if cc["PrecacheLonaPoseBitmaps"] == 1 && cc["PrecacheLonaAllBitmaps"] != 1
                  ::Cache.precache_lona_prt_bitmap("chcg") if cc["PrecacheLonaChcgBitmaps"] == 1 && cc["PrecacheLonaAllBitmaps"] != 1
                  ::Cache.precache_lona_prt_bitmap("all")  if cc["PrecacheLonaAllBitmaps"] == 1
                  ::Cache.precache_npc_prt_bitmap          if cc["PrecacheNpcPrtBitmaps"] == 1
                end
                dt = (::Time.now.to_f - t0) * 1000.0
                ::JPPerf.log(sprintf("BOOT_CACHE HIT: load_normal_database=%.1fms", dt))
                return
              end

              ::JPBootCache.captured_npc_portraits = nil
              ::JPBootCache.capturing = true
              begin
                jpopt_load_normal_database(*args)
              ensure
                ::JPBootCache.capturing = false
              end
              t_load = (::Time.now.to_f - t0) * 1000.0
              saved = ::JPBootCache.save_cache(fp)
              if saved
                ::JPPerf.log(sprintf("BOOT_CACHE MISS: load_normal_database=%.1fms save_cache=%.1fms size=%dKB", t_load, saved[0] * 1000.0, saved[1]))
              else
                ::JPPerf.log(sprintf("BOOT_CACHE MISS (not saved): load_normal_database=%.1fms", t_load))
              end
            end
          end
        end
      end
    end
  rescue Exception => e
    ::JPPerf.log("[PERF ERR Patch9 BootCache] #{e.class}: #{e.message}")
  end

  ::JPPerf.log("LonaRPG JoiPlay Perf Patch active (is_mkxp=#{is_mkxp})")
rescue Exception => e
  ::MKXP.puts("[PERF TOP ERR] #{e.class}: #{e.message}") if defined?(::MKXP) && ::MKXP.respond_to?(:puts)
end
