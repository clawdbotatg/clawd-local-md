import Foundation

/// The curated medical corpus. Ships in the binary, works with zero bars.
///
/// This is the app's source of truth for "how seriously should I take this" —
/// see `TriageTable` for why the model is never asked. Entries err toward
/// care: where a minor finding shares a name or a look with a serious one,
/// the serious entry is the one that fires, and nothing here ever says "this
/// is nothing." The app is NOT A DOCTOR; every note is a first look plus the
/// triggers that mean a clinician should take the second one.
///
/// `names` are matched whole-word and case-insensitively against the model's
/// identification. Include the common condition name, the clinical name, and
/// the plain visual descriptions a vision model actually produces. Never use
/// an alias that is generic on its own ("rash", "bump", "cut", "burn") — an
/// unmatched generic must fall to the category default, not a random entry.
///
/// `note` is printed to the user verbatim as the authoritative answer, so it
/// must be factually correct, short, and end with when to escalate. `source`
/// is the public guidance the note is drawn from (AAD = American Academy of
/// Dermatology, AAO = American Academy of Ophthalmology). Coverage
/// priorities, in order: findings where waiting is dangerous (cellulitis,
/// petechiae, melanoma features, animal bites), the look-alike pairs people
/// get wrong, then the common minor findings people actually photograph.
extension TriageTable {
    static let json = """
        [
        {"names":["ringworm","tinea","tinea corporis","ring-shaped rash","circular rash","ring rash"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Ring-shaped scaly patches are usually ringworm — a common fungal infection, not a worm. An over-the-counter antifungal cream used for 2 to 4 weeks typically clears it; it spreads by contact, so don't share towels. See a clinician if it's on the scalp, keeps spreading, or isn't better after 2 weeks."},

        {"names":["hives","urticaria","welts","wheals"],
         "category":"rash","level":"watch","source":"AAD",
         "note":"Raised itchy welts that move around and fade within hours are usually hives, often from an allergic trigger; an antihistamine helps. Get emergency help NOW if there is any swelling of the lips, tongue, or throat, trouble breathing, or dizziness — that's anaphylaxis, not a skin problem. Hives that keep returning for weeks deserve a clinician visit."},

        {"names":["eczema","atopic dermatitis","dry itchy patches"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Dry, itchy, inflamed patches are commonly eczema. Fragrance-free moisturizer several times a day plus 1% hydrocortisone for flares is the standard first step. See a clinician if it oozes, crusts, or is painful (possible infection), covers a large area, or disrupts sleep."},

        {"names":["contact dermatitis","allergic skin reaction"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"An itchy rash where something touched the skin — soaps, metals, plants, cosmetics — is usually contact dermatitis. Wash the area, avoid the trigger, and use hydrocortisone for the itch. See a clinician if it involves the face or genitals, blisters badly, or keeps spreading."},

        {"names":["poison ivy rash","urushiol rash","poison oak rash","poison sumac rash"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Streaky, blistering, intensely itchy patches after being outdoors fit a poison ivy/oak/sumac reaction. Wash skin, clothes, and anything else the plant oil touched; the rash itself isn't contagious and clears in 1 to 3 weeks. See a clinician if it's on the face, eyes, or genitals, covers a large area, or you develop fever or pus."},

        {"names":["shingles","herpes zoster","painful band of blisters"],
         "category":"rash","level":"urgent","source":"CDC",
         "note":"A painful, blistering band on ONE side of the body fits shingles. Antiviral medicine works best when started within 72 hours of the rash appearing, so see a clinician today — and if it's anywhere near an eye or the tip of the nose, treat it as an emergency, because it can threaten vision."},

        {"names":["cellulitis","spreading redness","red streaks","warm swollen red skin"],
         "category":"rash","level":"urgent","source":"Mayo Clinic",
         "note":"Skin that is red, warm, swollen, tender, and expanding fits cellulitis — a bacterial infection that spreads. This needs a clinician the same day. Red streaks running from the area, fever, chills, or rapid spreading mean emergency care now."},

        {"names":["impetigo","honey-colored crusts","honey colored crusts"],
         "category":"rash","level":"soon","source":"AAD",
         "note":"Sores that ooze and dry into honey-colored crusts, often around the nose and mouth, fit impetigo — a contagious bacterial infection that usually needs prescription treatment. Keep it covered, don't share towels, and see a clinician in the next day or two."},

        {"names":["heat rash","prickly heat","miliaria"],
         "category":"rash","level":"routine","source":"Mayo Clinic",
         "note":"Tiny prickly bumps after heat and sweat fit heat rash. It clears on its own with cooling, loose clothing, and keeping the skin dry. See a clinician if the bumps fill with pus, the area swells, or you develop fever."},

        {"names":["rosacea","facial redness with bumps"],
         "category":"rash","level":"watch","source":"AAD",
         "note":"Persistent facial redness with flushing and small bumps fits rosacea. It's common and very treatable, but prescription options work far better than anything over the counter — worth a dermatology visit. If your eyes are gritty, red, or irritated too, mention it: eye involvement needs attention."},

        {"names":["athlete's foot","athletes foot","tinea pedis"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Itchy, peeling, cracked skin between the toes fits athlete's foot. Over-the-counter antifungal creams work well; keep feet dry and change socks daily. If you have diabetes, see a clinician for ANY foot problem. Otherwise escalate if it's raw, spreading to the nails, or not better in 2 weeks."},

        {"names":["jock itch","tinea cruris"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"An itchy red ring spreading from the groin fold fits jock itch, a fungal infection. Over-the-counter antifungals plus keeping the area dry usually clear it in a few weeks. See a clinician if it's not improving, is raw or blistered, or keeps coming back."},

        {"names":["pityriasis rosea","herald patch","christmas tree rash"],
         "category":"rash","level":"watch","source":"AAD",
         "note":"One larger scaly patch followed by a spray of smaller ones across the trunk fits pityriasis rosea, which fades on its own over 6 to 8 weeks. But it has serious mimics that a photo can't exclude, so it's worth one clinician visit to confirm — sooner if you're pregnant or the rash involves palms and soles."},

        {"names":["hand foot and mouth","hand-foot-and-mouth","blisters on palms and soles"],
         "category":"rash","level":"watch","source":"CDC",
         "note":"Small blisters on the palms, soles, and around the mouth fit hand-foot-and-mouth disease, a viral illness that's common in kids and clears in about a week. Push fluids — mouth sores make kids refuse to drink. See a clinician if there are signs of dehydration, fever beyond 3 days, or the child is very young or seems very ill."},

        {"names":["chickenpox","chicken pox","varicella"],
         "category":"rash","level":"soon","source":"CDC",
         "note":"An itchy rash appearing in crops — spots, blisters, and scabs all present at once — fits chickenpox. Call a clinician to confirm (call ahead; it's very contagious). It's usually mild in children but riskier for adults, pregnant women, and newborns, who should be seen promptly."},

        {"names":["scabies","burrow tracks","intense night itching"],
         "category":"rash","level":"soon","source":"CDC",
         "note":"Intense itching that's worst at night, with tiny raised tracks between fingers or at the wrists, fits scabies. It needs a prescription cream, and everyone in close contact should be treated at the same time. It has nothing to do with hygiene. See a clinician in the next day or two."},

        {"names":["petechiae","pinpoint red dots","purpura","blood spots under the skin"],
         "category":"rash","level":"urgent","source":"Mayo Clinic",
         "note":"Pinpoint red or purple dots that do NOT fade when pressed can signal a blood or serious infection problem. With fever, unusual bruising, or feeling ill, this is an emergency. Even without other symptoms, unexplained non-blanching spots deserve same-day medical care."},

        {"names":["bullseye rash","bull's-eye rash","target rash","erythema migrans","expanding ring around a tick bite"],
         "category":"rash","level":"urgent","source":"CDC",
         "note":"An expanding ring or bullseye around a tick bite fits erythema migrans, the classic early sign of Lyme disease. Early antibiotics are highly effective, so see a clinician promptly — today or tomorrow — and mention the tick exposure, even if you never saw the tick and even if you feel fine."},

        {"names":["psoriasis","silvery scales","scaly plaques"],
         "category":"rash","level":"watch","source":"AAD",
         "note":"Thick, well-defined red patches with silvery scale — often on elbows, knees, or scalp — fit psoriasis. It's chronic but modern treatments work well, so a dermatology visit is worthwhile. If you also have joint pain or stiffness, say so: psoriatic arthritis is treatable and shouldn't wait."},

        {"names":["folliculitis","infected hair follicles","razor bumps"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Small pimple-like bumps centered on hair follicles fit folliculitis. Warm compresses and keeping the area clean usually settle it; stop shaving the area for a bit. See a clinician if it spreads, becomes painful or boil-like, or keeps recurring."},

        {"names":["keratosis pilaris","chicken skin","rough arm bumps"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Tiny rough bumps on the backs of the arms or thighs — so-called chicken skin — fit keratosis pilaris, which is harmless and very common. Moisturizers with urea or lactic acid smooth it. Nothing to escalate unless it becomes red, itchy, or painful."},

        {"names":["measles","rubeola"],
         "category":"rash","level":"urgent","source":"CDC",
         "note":"A blotchy rash spreading from the face downward after fever, cough, and red eyes fits measles, which is extremely contagious. Call a clinician BEFORE going in so they can protect other patients, and get seen the same day — especially for infants, pregnant women, or anyone unvaccinated."},

        {"names":["diaper rash","nappy rash"],
         "category":"rash","level":"routine","source":"Mayo Clinic",
         "note":"Red, irritated skin in the diaper area is usually diaper rash. Frequent changes, gentle cleaning, air time, and a zinc-oxide barrier cream typically clear it in a few days. See a clinician if it's raw, blistered, has pus, comes with fever, or isn't better after 3 days — bright-red rash with satellite spots may be yeast and needs its own cream."},

        {"names":["intertrigo","rash in skin folds"],
         "category":"rash","level":"routine","source":"AAD",
         "note":"Red, raw-feeling rash inside skin folds — under breasts, in the groin, under the belly — fits intertrigo, from skin-on-skin moisture. Keep the fold clean and dry; a barrier cream helps. Because yeast often joins in, see a clinician if it's not better in a week, is raw or weeping, or smells."},

        {"names":["mole","nevus","beauty mark"],
         "category":"mole","level":"watch","source":"AAD",
         "note":"Most moles are harmless, and a stable, single-colored, symmetric mole is usually nothing to worry about."},

        {"names":["atypical mole","irregular mole","asymmetric mole","changing mole","multicolored mole","mole with uneven border"],
         "category":"mole","level":"soon","source":"AAD",
         "note":"A mole that is asymmetric, has an uneven border, more than one color, is larger than a pencil eraser, or has changed is exactly what dermatologists want to see in person. Book a skin check in the coming days — most such moles are still benign, but this is the category where looking early pays."},

        {"names":["melanoma"],
         "category":"mole","level":"urgent","source":"AAD",
         "note":"If a spot looks like it could be melanoma, that question is answered by a dermatologist and usually a biopsy — never by a photo. Get an appointment promptly and say the word melanoma when you book; clinics triage that word fast. Found early, melanoma is very treatable."},

        {"names":["age spot","liver spot","solar lentigo","sun spot"],
         "category":"mole","level":"watch","source":"AAD",
         "note":"Flat, uniform brown spots on sun-exposed skin in adults are usually harmless age spots (solar lentigines)."},

        {"names":["skin tag","acrochordon"],
         "category":"growth","level":"routine","source":"AAD",
         "note":"A small, soft flap of skin on a stalk fits a skin tag — harmless and common where skin rubs. Don't cut or tie it off yourself. See a clinician if it changes color, grows quickly, bleeds, or hurts, or if you'd like it removed."},

        {"names":["wart","verruca","plantar wart"],
         "category":"growth","level":"routine","source":"AAD",
         "note":"A rough, grainy growth — sometimes with tiny black dots — fits a wart, caused by a common virus. Over-the-counter salicylic acid used patiently for weeks works for most. See a clinician for warts on the face or genitals, warts that spread or hurt, or any foot problem if you have diabetes."},

        {"names":["seborrheic keratosis","stuck-on growth","waxy brown growth"],
         "category":"growth","level":"watch","source":"AAD",
         "note":"A waxy, warty, stuck-on-looking brown growth in an older adult fits a seborrheic keratosis — very common and harmless. But dark, scaly growths are also what some skin cancers imitate, so have a clinician confirm it once, and sooner if it grows fast, bleeds, itches, or looks different from your others."},

        {"names":["actinic keratosis","rough scaly patch","sandpaper patch"],
         "category":"growth","level":"soon","source":"AAD",
         "note":"A rough, sandpapery patch that keeps coming back on sun-exposed skin fits an actinic keratosis — sun damage that is considered precancerous. It's easily treated in a dermatology office, so book a visit in the coming days to weeks rather than watching it."},

        {"names":["basal cell carcinoma","pearly bump","sore that will not heal","non-healing sore"],
         "category":"growth","level":"soon","source":"AAD",
         "note":"A pearly or waxy bump, or a sore that bleeds, scabs, and never quite heals, fits basal cell carcinoma — the most common and least aggressive skin cancer. It grows slowly and is very treatable, but it doesn't go away on its own: book a dermatology appointment soon."},

        {"names":["cherry angioma","small red dome"],
         "category":"growth","level":"routine","source":"AAD",
         "note":"Small, smooth, cherry-red domes that appear with age are cherry angiomas — harmless clusters of blood vessels. See a clinician only if one bleeds a lot, changes rapidly, or you want it removed."},

        {"names":["lipoma","soft movable lump"],
         "category":"growth","level":"watch","source":"Mayo Clinic",
         "note":"A soft, doughy lump that moves under the skin fits a lipoma — a benign fat growth. Still, any NEW lump deserves one professional confirmation, and a lump that is hard, fixed in place, growing, or painful should be seen soon rather than watched."},

        {"names":["cyst","sebaceous cyst","epidermoid cyst"],
         "category":"growth","level":"watch","source":"AAD",
         "note":"A round bump under the skin, sometimes with a central pore, fits an epidermoid cyst. Don't squeeze it — that's how they get infected. See a clinician if it becomes red, painful, or swollen (it may need draining), grows steadily, or you want it removed."},

        {"names":["keloid","raised scar"],
         "category":"growth","level":"routine","source":"AAD",
         "note":"A scar that grew beyond the original wound into a raised, smooth mound fits a keloid. It's harmless but can itch or keep growing; dermatologists have several options (injections, silicone sheets) if it bothers you. No urgency unless it's painful or changing fast."},

        {"names":["milia","tiny white bumps"],
         "category":"growth","level":"routine","source":"AAD",
         "note":"Tiny, hard white bumps — often around the eyes — fit milia, harmless keratin pearls. They usually clear on their own; don't squeeze them. A dermatologist can extract stubborn ones. Nothing to escalate."},

        {"names":["acne","pimple","zit","blackhead","whitehead","cystic acne"],
         "category":"growth","level":"routine","source":"AAD",
         "note":"Pimples, blackheads, and whiteheads are acne. Benzoyl peroxide or adapalene, used consistently for 6 to 8 weeks, helps most people; don't pick. See a dermatologist for deep painful cysts, scarring, or acne that OTC care isn't touching — prescription treatment prevents scars you can't undo later."},

        {"names":["tick bite","embedded tick","tick"],
         "category":"bite","level":"soon","source":"CDC",
         "note":"Remove a tick promptly: fine-tipped tweezers, grip close to the skin, pull straight up — no matches, no petroleum jelly. Note the date. Watch the area for 30 days: an expanding ring or bullseye rash, fever, chills, or body aches mean see a clinician right away and mention the tick. If it was attached more than a day in a Lyme area, it's reasonable to call a clinician now about preventive treatment."},

        {"names":["spider bite","bit by a spider","spider bit me"],
         "category":"bite","level":"watch","source":"Mayo Clinic",
         "note":"Most spider bites cause only a small red bump that settles with washing, a cold pack, and time — and most suspected spider bites are actually something else. See a clinician the same day if the center darkens or blisters, pain spreads or intensifies, or you develop fever, chills, or muscle cramps — those can signal a recluse or widow bite."},

        {"names":["black widow","brown recluse","black widow bite","brown recluse bite","recluse bite","widow bite"],
         "category":"bite","level":"soon","source":"Mayo Clinic",
         "note":"A suspected black widow or brown recluse bite deserves medical care today. Wash the area, use a cold pack, and keep the limb still on the way. Go now — not later — if pain spreads or intensifies, the center darkens or blisters, or you develop fever, chills, sweating, or muscle cramps."},

        {"names":["bee sting","wasp sting","hornet sting","yellow jacket sting"],
         "category":"bite","level":"watch","source":"Mayo Clinic",
         "note":"Scrape the stinger out sideways if it's still there, wash, and use a cold pack; local swelling and itching for a day or two is normal. Call 911 for any trouble breathing, swelling of the face, lips, or tongue, hives away from the sting site, or dizziness — that's an emergency allergic reaction. Many stings at once, or a sting inside the mouth, also deserve prompt care."},

        {"names":["mosquito bite"],
         "category":"bite","level":"routine","source":"CDC",
         "note":"Itchy bumps after being outdoors fit mosquito bites; a cold pack and anti-itch cream are enough. See a clinician if a bite area keeps growing and hardening, or if you develop fever, aches, or a rash after travel to areas with mosquito-borne illness."},

        {"names":["bed bug bite","bites in a line"],
         "category":"bite","level":"routine","source":"AAD",
         "note":"Itchy welts in a line or cluster, appearing overnight, fit bed bug bites. The bites themselves heal with anti-itch cream — the real problem is the infestation, which needs professional pest treatment. See a clinician only if bites blister, look infected, or you have a strong allergic reaction."},

        {"names":["flea bite"],
         "category":"bite","level":"routine","source":"AAD",
         "note":"Clusters of small itchy bumps around the ankles and lower legs, especially with pets at home, fit flea bites. Treat the itching with OTC cream, and treat the pets and home for fleas. See a clinician if bites blister, spread widely, or look infected from scratching."},

        {"names":["animal bite","dog bite","cat bite","bit by a dog","bitten by a dog","dog bit me","bit by a cat","bitten by a cat","cat bit me","bit by an animal","bitten by an animal","raccoon bite","bat bite","bit by a bat"],
         "category":"bite","level":"urgent","source":"CDC",
         "note":"Wash any animal bite thoroughly with soap and running water right away, then get medical care the same day: bites infect quickly (cat bites especially), you may need antibiotics or a tetanus booster, and a clinician must assess rabies risk — mention whether the animal was known and vaccinated. Deep wounds, face or hand bites, and bites from strays or wild animals should not wait at all."},

        {"names":["human bite","bit by a person","someone bit me"],
         "category":"bite","level":"urgent","source":"Mayo Clinic",
         "note":"Human bites that break the skin infect more often than most animal bites — including cuts on knuckles from contact with teeth. Wash well and get medical care the same day; these often need preventive antibiotics."},

        {"names":["snake bite","snakebite","bit by a snake","bitten by a snake","snake bit me","rattlesnake","copperhead","cottonmouth","water moccasin","coral snake"],
         "category":"bite","level":"urgent","source":"CDC",
         "note":"Treat any snake bite as an emergency: call 911 or get to an ER now, keep the bitten limb still and roughly level with the heart, and remove rings or tight items before swelling. Do NOT cut the wound, try to suck out venom, apply ice or a tourniquet, or waste time catching the snake — a photo from a safe distance is plenty."},

        {"names":["fire ant sting","fire ant bite"],
         "category":"bite","level":"watch","source":"Mayo Clinic",
         "note":"Clusters of burning bumps that turn into small pus-filled blisters within a day fit fire ant stings; the pustules are normal, not infected — don't pop them. Cold packs and antihistamines help. Call 911 for trouble breathing, face or throat swelling, or widespread hives; see a clinician if a sting area keeps spreading or looks truly infected."},

        {"names":["chigger bite"],
         "category":"bite","level":"routine","source":"Mayo Clinic",
         "note":"Intensely itchy red bumps around the ankles, waistband, or skin folds after time in grass or brush fit chigger bites. The mites are already gone — a good shower and anti-itch cream are the treatment. See a clinician only if bites look infected from scratching or the itching is unbearable."},

        {"names":["minor burn","first-degree burn","first degree burn","small red burn"],
         "category":"burn","level":"routine","source":"Mayo Clinic",
         "note":"A small burn that's red and painful but not blistered: cool it under cool (not icy) running water for 10 to 20 minutes, then cover loosely. No ice, no butter, no toothpaste. See a clinician if it's larger than your palm, on the face, hands, feet, genitals, or over a joint, or if it blisters after all."},

        {"names":["blistering burn","second-degree burn","second degree burn","burn with blisters"],
         "category":"burn","level":"soon","source":"Mayo Clinic",
         "note":"A burn that blisters is at least partial-thickness. Cool it with running water, don't pop the blisters, and cover loosely. Get medical care promptly if it's bigger than a few inches, on the face, hands, feet, genitals, or a joint, or shows signs of infection — and treat any burn on a baby or an elderly person as worth being seen."},

        {"names":["sunburn"],
         "category":"burn","level":"routine","source":"AAD",
         "note":"Cool showers, plain moisturizer or aloe, extra water, and ibuprofen cover most sunburns; leave blisters intact. See a clinician for widespread blistering, fever, chills, headache, or confusion — and remember each blistering sunburn raises lifetime skin-cancer risk, so this one earns better sunscreen next time."},

        {"names":["chemical burn"],
         "category":"burn","level":"urgent","source":"Mayo Clinic",
         "note":"Rinse a chemical burn under running water for at least 20 minutes, remove contaminated clothing and jewelry while rinsing, and call Poison Control (1-800-222-1222 in the US) or get emergency care. Do not try to neutralize the chemical. A chemical burn to the eye: rinse continuously and call 911."},

        {"names":["electrical burn"],
         "category":"burn","level":"urgent","source":"Mayo Clinic",
         "note":"An electrical burn can be small on the surface and serious underneath — current damages tissue along its path, including the heart. Get emergency care for any electrical burn beyond a trivial static-type contact, even if the visible mark looks minor."},

        {"names":["minor cut","small cut","scrape","abrasion","paper cut"],
         "category":"wound","level":"routine","source":"Mayo Clinic",
         "note":"Press to stop bleeding, rinse under running water, dab on antibiotic ointment, and cover. See a clinician if the edges gape open, bleeding won't stop after 10 minutes of steady pressure, there's dirt you can't rinse out, the area is numb, or your tetanus shot is more than 5 years old for a dirty wound."},

        {"names":["deep cut","gaping wound","laceration","gaping cut"],
         "category":"wound","level":"urgent","source":"Mayo Clinic",
         "note":"A cut whose edges gape open, shows fat or muscle, or won't stop bleeding needs closing — and stitches or glue work best within hours, so go now, not tomorrow. Keep firm pressure on it on the way. Cuts over joints, on the face, or from something dirty or rusty especially need professional care."},

        {"names":["puncture wound","stepped on a nail","rusty nail","stepped on a rusty nail","nail went through"],
         "category":"wound","level":"soon","source":"Mayo Clinic",
         "note":"Punctures look small but seal bacteria deep inside, so they infect easily. Let it bleed a little, wash well, and see a clinician in the next day — especially for a nail through a shoe, an animal-tooth puncture, anything deep or dirty, or if your tetanus shot isn't current. Watch closely for spreading redness, warmth, or pus."},

        {"names":["infected wound","pus","wound with pus","increasing redness around a wound"],
         "category":"wound","level":"urgent","source":"Mayo Clinic",
         "note":"A wound that's getting MORE red, warm, swollen, or painful after the first couple of days, or is draining pus, is likely infected and needs a clinician the same day. Fever, red streaks running from the wound, or rapidly spreading redness mean emergency care now."},

        {"names":["abscess","boil","furuncle"],
         "category":"wound","level":"soon","source":"AAD",
         "note":"A painful, swollen, pus-filled lump fits a boil or abscess. Warm compresses several times a day help it come to a head; do NOT squeeze or lance it yourself. See a clinician in the next day or two — many need proper drainage — and go the same day if it's on the face, growing fast, or you have a fever."},

        {"names":["skin ulcer","open sore that is not healing","wound that will not heal"],
         "category":"wound","level":"soon","source":"AAD",
         "note":"Any open sore that hasn't clearly healed in 2 to 3 weeks needs a clinician — non-healing wounds can reflect circulation problems, diabetes, pressure damage, or occasionally skin cancer, and all of those do better found early. On a foot or lower leg, or if you have diabetes, go promptly rather than waiting."},

        {"names":["bruise","contusion","black and blue mark"],
         "category":"wound","level":"routine","source":"Mayo Clinic",
         "note":"A bruise from a bump you remember will shift from purple to green to yellow and fade over about two weeks; ice early and elevation do the rest. See a clinician for bruises that appear without any injury, keep appearing, are unusually large for the bump, or come with nosebleeds or bleeding gums."},

        {"names":["blood blister"],
         "category":"blister","level":"routine","source":"AAD",
         "note":"A dark, fluid-filled blister after a pinch or friction is a blood blister. Leave it intact — the roof is the best bandage — pad it, and let it resorb over a week or two. See a clinician if it appeared with no clear injury, keeps recurring, or looks infected."},

        {"names":["friction blister","blister"],
         "category":"blister","level":"routine","source":"AAD",
         "note":"A fluid-filled blister from rubbing: leave it unpopped if you can, pad it (moleskin with a cutout works), and keep it clean. If it pops, don't peel the roof off. See a clinician for pus, spreading redness, or increasing pain — and if you have diabetes, any foot blister deserves professional eyes."},

        {"names":["pressure sore","bed sore","pressure ulcer"],
         "category":"wound","level":"soon","source":"Mayo Clinic",
         "note":"A persistent red or broken area over a bony spot in someone who sits or lies most of the day fits a pressure sore, and these worsen fast once the skin breaks. Get pressure off the spot immediately and have a clinician assess it promptly — early stages are very manageable; deep ones are serious."},

        {"names":["frostbite"],
         "category":"other","level":"urgent","source":"CDC",
         "note":"Cold, numb, waxy, pale or gray skin after cold exposure fits frostbite. Get somewhere warm and rewarm gently in warm (not hot) water — do NOT rub the skin or use direct dry heat. Blistering, blue-gray color, or skin that stays numb after rewarming needs emergency care."},

        {"names":["fungal nail","toenail fungus","onychomycosis","thick yellow nail"],
         "category":"nail","level":"routine","source":"AAD",
         "note":"A thickened, yellowed, crumbly nail fits nail fungus. Over-the-counter treatments are slow and often disappointing; prescription options from a clinician work much better if it bothers you. If you have diabetes, see a clinician for any foot or nail problem rather than treating it yourself."},

        {"names":["ingrown toenail","ingrown nail"],
         "category":"nail","level":"watch","source":"AAD",
         "note":"A nail edge digging into red, tender skin fits an ingrown toenail. Warm soaks several times a day and roomier shoes help early ones; don't dig at it. See a clinician if there's pus or spreading redness, if it keeps recurring — or promptly if you have diabetes or poor circulation."},

        {"names":["paronychia","infected cuticle","swollen nail fold"],
         "category":"nail","level":"soon","source":"AAD",
         "note":"A red, swollen, throbbing nail fold fits paronychia, an infection beside the nail. Warm soaks help a mild early one, but pus or spreading redness usually needs drainage or antibiotics — see a clinician in the next day or two rather than squeezing it yourself."},

        {"names":["dark streak under the nail","dark line under the nail","melanonychia","black line in the nail"],
         "category":"nail","level":"soon","source":"AAD",
         "note":"A new dark streak running the length of a nail can be entirely benign — but a melanoma under the nail looks exactly like this, especially a single new streak that widens, darkens, or spills pigment onto the skin around the nail. Have a dermatologist look at it soon; if there was a recent crush injury, say so, since trapped blood is the common mimic."},

        {"names":["bruised nail","subungual hematoma","black nail after injury"],
         "category":"nail","level":"watch","source":"AAD",
         "note":"A dark nail right after a slam or stub is usually blood trapped underneath. If it's painfully throbbing, a clinician can relieve the pressure — worth a same-day call. The mark should grow OUT with the nail over months; a dark area that doesn't move outward, or that appeared with no injury, should be seen promptly like a dark streak."},

        {"names":["stye","hordeolum","eyelid bump"],
         "category":"eye","level":"routine","source":"AAO",
         "note":"A tender red bump at the lash line fits a stye. Warm compresses for 10 minutes several times a day usually clear it in about a week; don't squeeze it, and skip eye makeup and contact lenses meanwhile. See a clinician if it doesn't improve in 1 to 2 weeks, swells the whole lid, or affects your vision."},

        {"names":["pink eye","conjunctivitis","red eye with discharge"],
         "category":"eye","level":"watch","source":"AAO",
         "note":"A pink, watery, gritty eye with discharge fits conjunctivitis, which is often viral and clears on its own — wash hands relentlessly, don't share towels, and pause contact lenses. Get same-day care for eye PAIN, light sensitivity, blurred vision that doesn't blink away, or a red eye in a newborn — those are not simple pink eye."},

        {"names":["subconjunctival hemorrhage","blood on the white of the eye","red patch on the eye"],
         "category":"eye","level":"watch","source":"AAO",
         "note":"A bright red patch on the white of the eye, painless and with normal vision, fits a subconjunctival hemorrhage — a broken surface vessel, often from a cough, sneeze, or strain. It looks dramatic and is usually harmless, clearing in 1 to 2 weeks. See a clinician if there's pain or vision change, it followed an injury, or it keeps happening."},

        {"names":["swollen eyelid","periorbital swelling","puffy eyelid"],
         "category":"eye","level":"soon","source":"AAO",
         "note":"A swollen eyelid is often a stye or an allergy — but swelling with spreading redness and warmth can be an infection of the tissue around the eye, which is serious. Get prompt care, and go to an ER for fever, pain when moving the eye, bulging, or any change in vision: those signs mean the infection may be behind the eye."},

        {"names":["canker sore","aphthous ulcer","mouth ulcer"],
         "category":"mouth","level":"routine","source":"Mayo Clinic",
         "note":"A small round white-gray sore with a red rim inside the mouth fits a canker sore; they sting for a few days and heal within two weeks. OTC numbing gels and salt-water rinses help. See a clinician or dentist about any mouth sore that lasts MORE than two weeks, keeps growing, or makes eating and drinking hard."},

        {"names":["cold sore","fever blister","herpes labialis"],
         "category":"mouth","level":"routine","source":"Mayo Clinic",
         "note":"Tingling followed by a cluster of small blisters on or near the lip fits a cold sore. It heals on its own in 1 to 2 weeks; antiviral creams or pills shorten it if started at the first tingle. It spreads by contact while blistered — no kissing or shared cups. See a clinician if sores are near an eye, widespread, or you're immunocompromised."},

        {"names":["oral thrush","thrush","white coating on the tongue"],
         "category":"mouth","level":"soon","source":"Mayo Clinic",
         "note":"Creamy white patches that wipe off to raw red spots fit oral thrush, a yeast overgrowth. It needs prescription antifungal treatment — and in a healthy adult it's also worth asking WHY it happened (inhalers, antibiotics, dentures, immune issues). See a clinician in the next few days."},

        {"names":["leukoplakia","white patch in the mouth"],
         "category":"mouth","level":"soon","source":"Mayo Clinic",
         "note":"A white patch in the mouth that does NOT wipe off and has lasted more than two weeks needs a dentist or clinician to look at it — most are harmless irritation, but some are precancerous, and tobacco or alcohol use raises the stakes. Book a visit soon; it's a quick look and often a quick answer."},

        {"names":["swollen lymph node","lump in the neck","swollen gland"],
         "category":"swelling","level":"watch","source":"Mayo Clinic",
         "note":"A tender, movable lump in the neck, armpit, or groin during or after an infection is usually a lymph node doing its job, and it should settle within 2 weeks. See a clinician about a node that is hard, fixed, painless, bigger than about an inch, still growing after 2 weeks, or paired with night sweats, fever, or weight loss."},

        {"names":["hernia","groin bulge"],
         "category":"swelling","level":"soon","source":"Mayo Clinic",
         "note":"A bulge in the groin or near the navel that appears with standing or straining and flattens when you lie down fits a hernia. It won't heal on its own, so have a clinician confirm it and plan next steps. Sudden severe pain at the bulge, a bulge that won't push back in, nausea, or vomiting is an emergency — the tissue may be trapped."},

        {"names":["swollen joint","joint swelling","swollen knee","swollen ankle"],
         "category":"swelling","level":"soon","source":"Mayo Clinic",
         "note":"A joint that's swollen without an injury to explain it deserves a clinician visit in the next day or two — gout, infection, and inflammatory arthritis all present this way, and all are treatable. A joint that is hot, red, and exquisitely painful, especially with fever, needs SAME-DAY care: an infected joint can be permanently damaged in days."},

        {"names":["angioedema","swollen lips","swollen face","swollen tongue"],
         "category":"swelling","level":"urgent","source":"Mayo Clinic",
         "note":"Sudden deep swelling of the lips, face, or tongue is angioedema, and the danger is the airway. Any trouble breathing, swallowing, or a voice change: call 911 now. Even without those, new facial or tongue swelling deserves same-day medical care — and if you take an ACE-inhibitor blood-pressure medicine, say so; it's a classic cause."},

        {"names":["swollen leg","one swollen leg","swollen calf"],
         "category":"swelling","level":"urgent","source":"Mayo Clinic",
         "note":"ONE swollen leg or calf — especially if it's also warm, tender, or achy — raises the question of a blood clot (DVT), which needs same-day medical evaluation; sudden shortness of breath or chest pain with it means 911. Both legs swelling evenly is a different, less immediate problem, but still worth a prompt visit."},

        {"names":["dandruff","seborrheic dermatitis","flaky scalp"],
         "category":"scalp","level":"routine","source":"AAD",
         "note":"Flaking with mild itch fits dandruff (seborrheic dermatitis). Medicated shampoos — zinc pyrithione, selenium sulfide, or ketoconazole — used a few times a week usually control it; rotate if one stops working. See a dermatologist if the scalp is inflamed, crusted, or not responding after a month."},

        {"names":["head lice","lice","nits"],
         "category":"scalp","level":"routine","source":"CDC",
         "note":"Itching plus tiny eggs glued to hair shafts near the scalp fits head lice. OTC permethrin or pyrethrin treatments plus thorough nit-combing work; retreat on the schedule the label gives, and wash recent bedding hot. Lice don't reflect hygiene. See a clinician if two proper treatment rounds fail."},

        {"names":["bald patch","alopecia areata","round patch of hair loss"],
         "category":"scalp","level":"watch","source":"AAD",
         "note":"A smooth, round patch of sudden hair loss fits alopecia areata, an autoimmune condition — hair often regrows, and dermatologists have treatments that help. Worth a visit to confirm and discuss options; go sooner if the scalp is scarred, scaly, or sore, or the loss is spreading quickly."},

        {"names":["cradle cap"],
         "category":"scalp","level":"routine","source":"Mayo Clinic",
         "note":"Greasy yellow scales on a baby's scalp fit cradle cap, which is harmless and clears on its own over weeks to months. Soften the scales with baby oil, brush gently, then shampoo. See a pediatrician if it spreads beyond the scalp, looks raw or infected, or the baby seems bothered."},

        {"names":["jaundice","yellow skin","yellowing of the eyes","yellow eyes"],
         "category":"other","level":"urgent","source":"Mayo Clinic",
         "note":"Yellowing of the skin or the whites of the eyes is jaundice, and it always deserves same-day medical evaluation — it signals a liver, bile-duct, or blood problem, not a skin problem. In a newborn, call the pediatrician today; deepening newborn jaundice is treated as an emergency."},

        {"names":["varicose veins","spider veins"],
         "category":"other","level":"watch","source":"Mayo Clinic",
         "note":"Bulging, twisted leg veins are varicose veins; thin surface webs are spider veins. Compression stockings, movement, and elevation ease symptoms, and treatment options exist if they ache. See a clinician for skin changes or sores near the ankle, bleeding from a vein, or a vein segment that suddenly becomes hard, red, and painful."},

        {"names":["hemorrhoid"],
         "category":"other","level":"watch","source":"Mayo Clinic",
         "note":"A tender lump at the anus with itching or bright-red blood on the paper fits a hemorrhoid; fiber, water, and sitz baths settle most within a week or two. But don't self-diagnose rectal bleeding forever: have a clinician confirm the source once, and go promptly for heavy bleeding, severe pain, fever, or new bleeding if you're over 45."},

        {"names":["vitiligo","white patches on the skin","loss of skin color"],
         "category":"other","level":"watch","source":"AAD",
         "note":"Well-defined patches where the skin has lost its color fit vitiligo, an autoimmune loss of pigment. It isn't dangerous or contagious, but a dermatologist can confirm it (a few conditions mimic it), discuss treatment, and check thyroid links. The patches sunburn easily — protect them."},

        {"names":["stretch marks","striae"],
         "category":"other","level":"routine","source":"AAD",
         "note":"Pink, red, or purple lines that fade toward silver fit stretch marks, from skin stretching faster than it can adapt — growth, pregnancy, weight change, or lifting. They're harmless and fade with time. Mention them to a clinician only if they appeared alongside easy bruising or long-term steroid use."}
        ]
        """
}
