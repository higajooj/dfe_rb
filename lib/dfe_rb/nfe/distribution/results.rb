module DfeRb
  module Nfe
    module Distribution
      DistributionResult = Data.define(:query, :code, :message, :environment, :application_version,
        :responded_at, :last_nsu, :max_nsu, :documents, :request_xml, :response_xml, :retry_at) do
        def status
          case code
          when 138 then :documents
          when 137 then :empty
          when 656 then :blocked
          when 108, 109 then :unavailable
          else :rejected
          end
        end

        def success? = [137, 138].include?(code)
        def empty? = status == :empty
        def blocked? = status == :blocked
        def unavailable? = status == :unavailable
        def rejected? = !success?
        def more? = query == :dist_nsu && code == 138 && !last_nsu.nil? && !max_nsu.nil? && last_nsu < max_nsu
      end

      ManifestationResult = Data.define(:key, :type, :sequence, :code, :message, :protocol, :registered_at,
        :event_xml, :return_xml, :request_xml, :response_xml) do
        def status
          case code
          when 135 then :registered
          when 136 then :registered_unlinked
          when 573 then :duplicate
          else :rejected
          end
        end

        def registered? = [135, 136].include?(code)
        def linked? = code == 135
        def duplicate? = code == 573
        def blocked? = code == 656
        def rejected? = !registered?

        def proc_xml
          Proc.event(event_xml, return_xml) if registered? && protocol && return_xml
        end

        def filename = "#{key}_#{type}_#{format("%02d", sequence)}-procEventoNFe.xml"
      end
    end
  end
end
