# frozen_string_literal: true

module Legion
  module Extensions
    module Agentic
      module Memory
        module Trace
          module Helpers
            module Decay
              TICK_INTERVAL = 60

              module_function

              # Power-law decay formula from spec:
              # new_strength = peak_strength * (ticks_since_access + 1)^(-base_decay_rate / (1 + emotional_intensity * E_WEIGHT))
              def compute_decay(peak_strength:, base_decay_rate:, ticks_since_access:, emotional_intensity: 0.0, **)
                return peak_strength if base_decay_rate.zero?
                return 0.0 if peak_strength.zero?

                e_weight = Helpers::Trace::E_WEIGHT
                effective_rate = base_decay_rate / (1.0 + (emotional_intensity * e_weight))
                new_strength = peak_strength * ((ticks_since_access + 1).to_f**(-effective_rate))
                new_strength.clamp(0.0, 1.0)
              end

              # Reinforcement formula from spec:
              # new_strength = min(1.0, current_strength + R_AMOUNT * IMPRINT_MULTIPLIER_if_applicable)
              def compute_reinforcement(current_strength:, imprint_active: false, **)
                r_amount = Helpers::Trace::R_AMOUNT
                multiplier = imprint_active ? Helpers::Trace::IMPRINT_MULTIPLIER : 1.0
                new_strength = current_strength + (r_amount * multiplier)
                new_strength.clamp(0.0, 1.0)
              end

              # Composite retrieval score from spec:
              # score = strength * recency_factor * emotional_weight * (1 + association_bonus)
              def compute_retrieval_score(trace:, query_time: nil, associated: false, **)
                query_time ||= Time.now.utc
                seconds_since = [query_time - ensure_time(trace[:last_reinforced]), 0].max
                half_life = Helpers::Trace::RETRIEVAL_RECENCY_HALF.to_f

                recency_factor = 2.0**(-seconds_since / half_life)
                emotional_weight = 1.0 + trace[:emotional_intensity]
                assoc_bonus = associated ? (1.0 + Helpers::Trace::ASSOCIATION_BONUS) : 1.0

                trace[:strength] * recency_factor * emotional_weight * assoc_bonus
              end

              # Determine storage tier based on last access time
              def compute_storage_tier(trace:, now: nil, **)
                now ||= Time.now.utc
                seconds_since = now - ensure_time(trace[:last_reinforced])

                if trace[:strength] <= Helpers::Trace::PRUNE_THRESHOLD
                  :erased
                elsif seconds_since <= Helpers::Trace::HOT_TIER_WINDOW
                  :hot
                elsif seconds_since <= Helpers::Trace::WARM_TIER_WINDOW
                  :warm
                else
                  :cold
                end
              end

              def ensure_time(value)
                return value if value.is_a?(Time)
                return Time.parse(value) if value.is_a?(String)

                Time.now.utc
              end
            end
          end
        end
      end
    end
  end
end
