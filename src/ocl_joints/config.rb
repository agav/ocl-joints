require 'json'

module OclJoints

  # Connector tables and library folders. Pure Ruby; main.rb keeps the JSON in %APPDATA%.
  #
  # { "library": [ "C:/folder", ... ],
  #   "rows": [ { "name": "minifix", "face": "f_d5x11.5", "edge": "g_minifix-edge",
  #               "learned": { "edge": 0, "face": 0 } }, ... ],
  #   "triples": [ { "name": "...", "face": "<through hole>", "edge": "<both edge panels>" }, ... ] }
  # rows are 2-panel connectors, triples 3-panel connectors (one through hole in the central panel).
  # "learned" holds the turns (0..3, 90 degrees each) of the last turned joint; it is optional.
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
      { library: [], rows: DEFAULT_ROWS.map(&:dup), triples: [] }
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
      { library: library, rows: _rows(data[:rows]), triples: _rows(data[:triples]) }
    end

    def _rows(list)
      Array(list).filter_map do |r|
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
    end

  end

end
