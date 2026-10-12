module DfeRb
  module Nfe
    module Distribution
      # The answer to a distribution request (DfeRb::Distribution::Result).
      DistributionResult = DfeRb::Distribution::Result

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
