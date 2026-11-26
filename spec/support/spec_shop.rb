# frozen_string_literal: true

# Reactors that cross each other's boundaries, for the topology specs:
#
#   Orders (decider)    PlaceOrder → OrderPlaced, ConfirmOrder → OrderConfirmed
#   Payments (decider)  ChargePayment → PaymentCharged
#   Checkout (decider)  reacts to OrderPlaced, dispatching ChargePayment,
#                       and to PaymentCharged, dispatching ConfirmOrder
#   Listings (projector, registered first) evolves from OrderPlaced and
#                       PaymentCharged
#   Shipment (machine)  starts a Parcel machine per parcel; Parcel finishes
#                       back into it
module SpecShop
  def self.command(name, *attrs) = Sourced::Command.define("spec_shop.#{name}") { attrs.each { |a| attribute a, String } }
  def self.event(name, *attrs) = Sourced::Event.define("spec_shop.#{name}") { attrs.each { |a| attribute a, String } }

  PlaceOrder = command(:place_order, :order_id)
  OrderPlaced = event(:order_placed, :order_id)
  ConfirmOrder = command(:confirm_order, :order_id)
  OrderConfirmed = event(:order_confirmed, :order_id)
  ChargePayment = command(:charge_payment, :order_id)
  PaymentCharged = event(:payment_charged, :order_id)
  Ship = command(:ship, :order_id)
  AddParcel = command(:add_parcel, :order_id, :parcel_id)
  Deliver = command(:deliver, :order_id, :parcel_id)

  class Listings < Sourced::Projector::EventSourced
    partition_by :order_id

    evolve(OrderPlaced) { |_context, _event| nil }
    evolve(PaymentCharged) { |_context, _event| nil }
    sync { |**| nil }
  end

  class Orders < Sourced::Decider
    partition_by :order_id

    command(PlaceOrder => OrderPlaced) { |_context, cmd| event OrderPlaced, order_id: cmd.payload.order_id }
    command(ConfirmOrder => OrderConfirmed) { |_context, cmd| event OrderConfirmed, order_id: cmd.payload.order_id }
  end

  class Payments < Sourced::Decider
    partition_by :order_id

    command(ChargePayment => PaymentCharged) { |_context, cmd| event PaymentCharged, order_id: cmd.payload.order_id }
  end

  class Checkout < Sourced::Decider
    partition_by :order_id

    reaction(OrderPlaced => ChargePayment) { |_context, evt| dispatch ChargePayment, order_id: evt.payload.order_id }
    reaction(PaymentCharged => ConfirmOrder) { |_context, evt| dispatch ConfirmOrder, order_id: evt.payload.order_id }
  end

  class Parcel < Sourced::Machine
    partition_by :order_id, :parcel_id

    started :added do
      command Deliver => :delivered
    end
    final :delivered
    stopped :lost
  end

  class Shipment < Sourced::Machine
    partition_by :order_id

    initial do
      command Ship => :shipping
    end

    state :shipping do
      command AddParcel, starts: Parcel
      children_done Parcel => :shipped
    end

    final :shipped
  end

  REACTORS = [Listings, Orders, Payments, Checkout, Shipment, Parcel].freeze
end
