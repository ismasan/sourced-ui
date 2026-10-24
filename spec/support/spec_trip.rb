# frozen_string_literal: true

# A machine with every kind of state the statechart draws: a trip planned in
# parallel regions, paid for in a part (a compound state) with a timer, and
# replanned through deep history.
#
#   initial ─Start─▶ planning ║ flight: initial ─ChooseFlight─▶ flight_chosen (final)
#                             ║ hotel:  initial ─ChooseHotel──▶ hotel_chosen (final)
#            planning ─done─▶ checkout [ paying ─Pay─▶ paid (final) ; after 15m ─Expire─▶ expired ]
#            checkout ─on_final paid─▶ booked (final)
#            checkout ─Replan─▶ planning (deep history)
#            planning, checkout ─Cancel─▶ cancelled (final)
class SpecTrip < Sourced::Machine
  partition_by trip_id: String
  message_prefix 'spec_trip'

  class Checkout < Sourced::Machine::Part
    part_of SpecTrip

    Paying = State(:paying)
    Paid = State(:paid)
    Expired = State(:expired)

    Pay = Command(:pay)
    Expire = Command(:expire)

    started Paying do
      after('15m' => Expire)

      command Pay => Paid
      command Expire => Expired
    end

    final Paid
    final Expired
  end

  Planning = State(:planning)
  FlightChosen = State(:flight_chosen)
  HotelChosen = State(:hotel_chosen)
  Booked = State(:booked)
  Cancelled = State(:cancelled)

  Start = Command(:start)
  ChooseFlight = Command(:choose_flight)
  ChooseHotel = Command(:choose_hotel)
  Replan = Command(:replan)
  Cancel = Command(:cancel)

  initial do
    command Start => Planning
  end

  state Planning do
    command Cancel => Cancelled

    region :flight do
      initial do
        command ChooseFlight => FlightChosen
      end

      final FlightChosen
    end

    region :hotel do
      initial do
        command ChooseHotel => HotelChosen
      end

      final HotelChosen
    end

    done Checkout
  end

  state Checkout do
    on_final Checkout::Paid => Booked
    command Replan => Planning.history(deep: true)
    command Cancel => Cancelled
  end

  final Booked
  final Cancelled
end
