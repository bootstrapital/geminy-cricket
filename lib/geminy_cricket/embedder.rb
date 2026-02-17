# frozen_string_literal: true

require "json"

module GeminyCricket
  class Embedder
    def initialize(model: Config.embedding_model, dimensions: Config.embedding_dimensions)
      @model = model
      @dimensions = dimensions
      @available = false
      @error_message = nil

      begin
        require "informers"
        @pipeline = Informers.pipeline("embedding", @model)
        @available = true
      rescue StandardError => e
        @error_message = e.message
      end
    end

    attr_reader :model, :dimensions, :error_message

    def available?
      @available
    end

    def embed(text)
      return nil unless available?
      return nil if text.to_s.strip.empty?

      raw = @pipeline.call(text.to_s)
      vector = normalize_vector(raw)
      return nil unless vector
      return nil unless vector.length == @dimensions

      vector
    rescue StandardError => e
      log_swallowed_error(
        event: "embedder_embed_failed",
        exception: e
      )
      nil
    end

    private

    def normalize_vector(raw)
      value = if raw.respond_to?(:to_a)
                raw.to_a
              else
                raw
              end

      return nil unless value.is_a?(Array)

      first = value.first
      value = first if first.is_a?(Array)
      return nil unless value.is_a?(Array)

      value.map(&:to_f)
    end

    def log_swallowed_error(event:, exception:)
      warn(
        JSON.generate(
          event: event,
          error_class: exception.class.name,
          message: exception.message
        )
      )
    end
  end
end
