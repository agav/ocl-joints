require 'json'

module OclJoints

  # Connector table and library folders. Pure Ruby; main.rb keeps the JSON in the SketchUp user settings.
  #
  # { "library": [ "C:/folder", ... ],
  #   "rows": [ { "name": "minifix", "face": "f_d5x11.5", "edge": "g_minifix-edge",
  #               "learned": { "edge": 0, "face": 0 } }, ... ] }
  # "learned" holds the turns (0..3, 90 degrees each) of the last placed pair; it is optional.
  module Config

    # Connector pairs used in lm.skp
    DEFAULT_ROWS = [
      { name: 'minifix', face: 'f_d5x11.5', edge: 'g_minifix-edge' },
      { name: 'minifix + dowels', face: 'g_minifix_shkant_front', edge: 'g_minifx_shkant_edge' },
      { name: 'confirmat', face: 'f_d7xFc', edge: 'f_d4.5x34' },
      { name: 'dowel 8', face: 'f_d8x12', edge: 'f_d8.5x25' },
    ].freeze

    module_function

    def default
      { library: [], rows: DEFAULT_ROWS.map(&:dup) }
    end

    # Parses and cleans a JSON string; returns the default for nil or invalid JSON
    def parse(json)
      return default if json.nil? || json.strip.empty?
      normalize(JSON.parse(json, symbolize_names: true))
    rescue JSON::ParserError
      default
    end

    def dump(config)
      JSON.pretty_generate(normalize(config))
    end

    def normalize(data)
      data = {} unless data.is_a?(Hash)
      library = Array(data[:library]).map { |f| f.to_s.strip }.reject(&:empty?)
      rows = Array(data[:rows]).filter_map do |r|
        next unless r.is_a?(Hash)
        row = { name: r[:name].to_s.strip, face: r[:face].to_s.strip, edge: r[:edge].to_s.strip }
        next if row[:face].empty? && row[:edge].empty?
        row[:name] = row[:edge] if row[:name].empty?
        learned = r[:learned]
        if learned.is_a?(Hash) && [ learned[:edge], learned[:face] ].all? { |k| k.is_a?(Integer) && k.between?(0, 3) }
          row[:learned] = { edge: learned[:edge], face: learned[:face] }
        end
        row
      end
      { library: library, rows: rows }
    end

  end

end
