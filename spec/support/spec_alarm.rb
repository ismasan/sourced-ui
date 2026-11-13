# frozen_string_literal: true

# A machine with entry and exit actions, and a timer whose delay its context
# computes: an alarm that, armed, sends an SOS after a while.
class SpecAlarm < Sourced::Machine
  partition_by alarm_id: String
  message_prefix 'spec_alarm'

  SosDelay = ->(_context) { 60 }

  Armed = State(:armed)
  Disarmed = State(:disarmed)

  Arm = Command(:arm)
  Disarm = Command(:disarm)
  Notify = Command(:notify)
  SendSOS = Command(:send_sos)

  initial do
    command Arm => Armed
  end

  state Armed do
    entry Notify
    exit Notify
    after(SosDelay => SendSOS)
    command SendSOS => Disarmed
    command Disarm => Disarmed
  end

  state Disarmed do
    command Notify => Disarmed
  end
end
