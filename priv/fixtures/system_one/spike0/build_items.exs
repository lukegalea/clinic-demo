# Builds items.jsonl, the spike-0 labelled items. Synthetic, CC0-1.0.
#
#     elixir priv/fixtures/system_one/spike0/build_items.exs
#
# Every item is fictional. Patient names are pet names chosen to be obviously
# made up; there are no owners, addresses or clinics that exist.
#
# Labels are the AUTHOR's intended labels (labeller "author"). The blind
# second labelling the ticket asks for has not happened yet: `second_label` is
# null on every item until it does, and items where the two disagree are then
# dropped (see docs/spikes/system-one-spike-0.md, "Labelling protocol").
#
# Token counts are approximate: bytes of the JSON state / 4. laya's tokenizer
# is not available here, so the length probes aim a little past each boundary.

defmodule Spike0.Items do
  @filler [
    "Vaccination history: primary course as a puppy, boosters given each spring since.",
    "Diet: dry food twice daily with a spoon of wet food in the evening, fresh water always available.",
    "Weight log: 18.2 kg last spring, 18.6 kg last summer, 18.4 kg today.",
    "Behaviour: friendly with staff, a little anxious in the car, settles quickly in the consult room.",
    "Housing: lives indoors with access to a fenced garden, no other animals in the household.",
    "Parasite control: monthly spot-on applied at home, wormed every three months.",
    "Exercise: two walks a day, off lead in the park, swims in summer.",
    "Previous visit: nail trim and anal gland expression, nothing else of note.",
    "Owner reports normal appetite, normal thirst, normal urination and normal stools.",
    "Coat in good condition, mild tartar on the upper premolars, ears clean on otoscopy.",
    "Heart and lungs auscultated: regular rhythm, no murmur, clear lung fields.",
    "Abdominal palpation unremarkable, lymph nodes normal size, temperature 38.6 C."
  ]

  def noul do
    [
      # clear positives
      pos("n-pos-01", "Otitis externa, left ear. Ear drops twice daily for 10 days. Recheck booked in 14 days to confirm the ear has resolved."),
      pos("n-pos-02", "Twelve-year-old cat with early kidney disease. Started on a renal diet. Bloods to be repeated in 8 weeks; the appointment was made at the desk before leaving."),
      pos("n-pos-03", "Non-weight-bearing lameness right hind, suspected cruciate rupture. Referred to the orthopaedic service at Riverbend Referrals; referral letter sent today."),
      pos("n-pos-04", "Laceration on the left fore paw, sutured under sedation. Suture removal in 10 days, booked for the 14th. Meloxicam for 5 days, then stop."),
      pos("n-pos-05", "Pyoderma on the ventral abdomen. Antibiotic course for 14 days, ending on the 21st. Nurse to phone on the 22nd to check the skin has cleared."),
      pos("n-pos-06", "Hyperthyroid cat started on methimazole. T4 recheck in three weeks; owner booked it online while in the waiting room."),
      # clear negatives
      neg("n-neg-01", "clear_negative", "Annual vaccination given. Healthy on examination. Weight stable at 4.2 kg."),
      neg("n-neg-02", "clear_negative", "Nail trim only. No concerns raised by the owner."),
      neg("n-neg-03", "clear_negative", "Owner asked about diet. Discussed moving to a senior food gradually over a week. General advice only."),
      neg("n-neg-04", "clear_negative", "Microchip implanted and scanned; number registered."),
      neg("n-neg-05", "clear_negative", "Puppy visit. Healthy, eating well, playing normally. Socialisation advice given."),
      neg("n-neg-06", "clear_negative", "Mild conjunctivitis from last week has fully resolved. Discharged."),
      # hard negatives
      neg("n-hard-01", "hard_negative", "Wound has healed well. No recheck needed; told the owner there is nothing further to do.", "negation"),
      neg("n-hard-02", "hard_negative", "Patient: Nutmeg. Came in with her sister Pepper. Pepper's recheck is booked for next Tuesday. Nutmeg is healthy and needs nothing further.", "plan belongs to a different animal"),
      neg("n-hard-03", "hard_negative", "Patient: Juniper. A recheck had been booked for the 3rd, but the owner cancelled it at the desk today and does not want to rebook.", "plan cancelled"),
      neg("n-hard-04", "hard_negative", "Patient: Pickle. Mild gastroenteritis. Bland diet for 48 hours. Come back if the vomiting returns or she stops eating.", "conditional only"),
      neg("n-hard-05", "hard_negative", "Health check, all normal.\nPlan: Recheck in 7 days.\n(Plan line is the consult template's default text and was not edited; nothing is planned.)", "copy-pasted template line"),
      neg("n-hard-06", "hard_negative", "Recommended a dental referral for the fractured carnassial. Owner declined for cost reasons and understands the risk.", "follow-up declined"),
      neg("n-hard-07", "hard_negative", "Small fatty lump on the flank. Advised the owner to keep an eye on it and mention it at the next annual visit.", "vague monitoring, general advice"),
      # length probes: decisive sentence LAST, so silent truncation from the end flips the answer
      probe("n-len-0300-pos", 300, true, "Plan: recheck booked in two weeks to reassess the skin."),
      probe("n-len-0300-neg", 300, false, "Plan: no recheck needed; discharged."),
      probe("n-len-0900-pos", 900, true, "Plan: recheck booked in two weeks to reassess the skin."),
      probe("n-len-0900-neg", 900, false, "Plan: no recheck needed; discharged."),
      probe("n-len-1100-pos", 1100, true, "Plan: recheck booked in two weeks to reassess the skin."),
      probe("n-len-1100-neg", 1100, false, "Plan: no recheck needed; discharged."),
      probe("n-len-1600-pos", 1600, true, "Plan: recheck booked in two weeks to reassess the skin."),
      probe("n-len-1600-neg", 1600, false, "Plan: no recheck needed; discharged.")
    ]
  end

  def choice do
    [
      c("c-emer-01", "clear", :emergency, "He collapsed on his walk and his gums look pale.", "dog", "adult"),
      c("c-emer-02", "clear", :emergency, "Having a seizure that has lasted five minutes and won't stop.", "dog", "senior"),
      c("c-emer-03", "clear", :emergency, "Ate a whole bar of dark chocolate about an hour ago.", "dog", "juvenile"),
      c("c-emer-04", "clear", :emergency, "Male cat straining in the litter tray all morning, crying, no urine coming out.", "cat", "adult"),
      c("c-urg-01", "clear", :urgent, "Vomiting since last night, about six times, can't keep water down.", "dog", "adult"),
      c("c-urg-02", "clear", :urgent, "Won't bear weight on his back leg after jumping off the sofa.", "dog", "adult"),
      c("c-urg-03", "clear", :urgent, "Has not eaten anything for two days and is hiding under the bed.", "cat", "senior"),
      c("c-urg-04", "clear", :urgent, "Squinting and pawing at her eye; the eye looks cloudy.", "cat", "adult"),
      c("c-soon-01", "clear", :soon, "Scratching his ears a lot this week, and there's a bit of a smell.", "dog", "adult"),
      c("c-soon-02", "clear", :soon, "Found a small soft lump on her side; she doesn't seem bothered by it.", "dog", "senior"),
      c("c-soon-03", "clear", :soon, "Mild limp on and off for a couple of weeks, still running around.", "dog", "adult"),
      c("c-soon-04", "clear", :soon, "Bit of dandruff and scratching, otherwise fine.", "rabbit", "adult"),
      c("c-rout-01", "clear", :routine, "Due his annual booster.", "dog", "adult"),
      c("c-rout-02", "clear", :routine, "Nail trim please.", "rabbit", "adult"),
      c("c-rout-03", "clear", :routine, "Health check before we go on holiday.", "cat", "adult"),
      c("c-rout-04", "clear", :routine, "Second puppy vaccination.", "dog", "juvenile"),
      c("c-hard-01", "hard", :soon, "Nail bled after I cut it too short; it stopped after ten minutes with flour on it.", "dog", "adult", "alarming words, resolved problem"),
      c("c-hard-02", "hard", :soon, "I'm panicking, she has sneezed twice today, but she's eating and playing normally.", "cat", "adult", "owner distress is not animal urgency"),
      c("c-hard-03", "hard", :emergency, "Breathing fast with her mouth open, and her tongue looks a bit blue.", "cat", "adult", "no keyword; open-mouth breathing in a cat"),
      c("c-hard-04", "hard", :emergency, "Won't feed since this morning and feels cold to touch.", "cat", "neonate", "age band carries the urgency"),
      c("c-hard-05", "hard", :soon, "Just wants his vaccination, but he's also been drinking loads and weeing more for a month.", "dog", "senior", "routine request hides a chronic sign"),
      c("c-hard-06", "hard", :emergency, "Hasn't eaten or passed droppings since yesterday.", "rabbit", "adult", "gut stasis in a rabbit; no keyword"),
      c("c-abst-01", "abstain", :insufficient_information, "Something's not right.", "dog", "adult"),
      c("c-abst-02", "abstain", :insufficient_information, "Please call me back.", "cat", "adult"),
      c("c-abst-03", "abstain", :insufficient_information, "Follow-up from last time.", "dog", "adult"),
      c("c-abst-04", "abstain", :insufficient_information, "As discussed.", "rabbit", "adult")
    ]
  end

  defp pos(id, notes), do: item(id, "notes_follow_up", %{"notes" => notes}, true, "clear_positive", nil)
  defp neg(id, stratum, notes, why \\ nil), do: item(id, "notes_follow_up", %{"notes" => notes}, false, stratum, why)

  defp probe(id, target, gold, last) do
    header = "Patient: Clementine, 6-year-old dog. Presented for itchy skin on the belly."
    notes = pad(header, last, target)
    item(id, "notes_follow_up", %{"notes" => notes}, gold, "length_probe",
      "target ~#{target} tokens; decisive sentence is last")
  end

  defp c(id, stratum, gold, reason, species, age_band, why \\ nil) do
    item(id, "presenting_urgency", %{"reason" => reason, "species" => species, "age_band" => age_band},
      Atom.to_string(gold), stratum, why)
  end

  defp pad(header, last, target) do
    Stream.cycle(@filler)
    |> Enum.reduce_while(header, fn sentence, acc ->
      candidate = acc <> " " <> sentence
      if tokens(%{"notes" => candidate <> " " <> last}) > target, do: {:halt, acc}, else: {:cont, candidate}
    end)
    |> Kernel.<>(" " <> last)
  end

  defp item(id, question, state, gold, stratum, why) do
    %{
      "id" => id,
      "question" => question,
      "state" => state,
      "gold" => gold,
      "labeller" => "author",
      "second_label" => nil,
      "stratum" => stratum,
      "approx_tokens" => tokens(state),
      "author_notes" => why
    }
  end

  def tokens(state), do: div(byte_size(JSON.encode!(state)), 4)
end

path = Path.join(__DIR__, "items.jsonl")
items = Spike0.Items.noul() ++ Spike0.Items.choice()
File.write!(path, Enum.map_join(items, "", &(JSON.encode!(&1) <> "\n")))

counts = Enum.frequencies_by(items, &{&1["question"], &1["stratum"]})
IO.puts("wrote #{length(items)} items to #{path}")
for {{q, s}, n} <- Enum.sort(counts), do: IO.puts("  #{q} #{s}: #{n}")
