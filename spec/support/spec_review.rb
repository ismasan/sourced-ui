# frozen_string_literal: true

# A part that escalates into a parallel checkpoint's history.
#
#   initial ─Start─▶ reviewing ║ pages: initial ─Read─▶ read (final)
#            reviewing ─Scan─▶ scanning [ pending ─Finish─▶ scanned (final) ]
#            scanning ─on_final scanned─▶ reviewing (history)
class SpecReview < Sourced::Machine
  partition_by doc_id: String
  message_prefix 'spec_review'

  class Scanning < Sourced::Machine::Part
    part_of SpecReview

    Pending = State(:pending)
    Scanned = State(:scanned)

    Finish = Command(:finish)

    started Pending do
      command Finish => Scanned
    end

    final Scanned
  end

  Reviewing = State(:reviewing)
  Read = State(:read)

  Start = Command(:start)
  ReadPage = Command(:read_page)
  Scan = Command(:scan)

  initial do
    command Start => Reviewing
  end

  state Reviewing do
    command Scan => Scanning

    region :pages do
      initial do
        command ReadPage => Read
      end

      final Read
    end
  end

  state Scanning do
    on_final Scanning::Scanned => Reviewing.history
  end
end
