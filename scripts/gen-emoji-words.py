"""Builds Packages/WispenCore/Sources/WispenCore/Resources/emoji_words.txt: for each English word, the best-matching emoji (up to 3), ranked.

Source: Unicode CLDR release 46 English annotations (emoji names and keywords), the standard
emoji keyword data. Only emoji in Wispen's catalog (no skin-tone
variants) are used.

Usage (CLDR files from https://github.com/unicode-org/cldr/tree/release-46/common):
  mkdir cldr && curl -L -o cldr/annotations_en.xml .../common/annotations/en.xml
               curl -L -o cldr/annotationsDerived_en.xml .../common/annotationsDerived/en.xml
  python3 scripts/gen-emoji-words.py cldr Packages/WispenCore/Sources/WispenCore/Resources/emoji.txt \
      Packages/WispenCore/Sources/WispenCore/Resources/emoji_words.txt
"""
import re, sys, html, collections
cldr, catalog_path, out_path = sys.argv[1:4]

catalog = []  # (emoji, name) in catalog order
for line in open(catalog_path, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line or line.startswith('@'): continue
    e, name = line.split('\t', 1)
    catalog.append((e, name))
order = {e: i for i, (e, _) in enumerate(catalog)}
by_bare = {e.replace('️', ''): e for e, _ in catalog}

names, keywords = {}, collections.defaultdict(list)
for f in ('annotations_en.xml', 'annotationsDerived_en.xml'):
    for m in re.finditer(r'<annotation cp="([^"]+)"( type="tts")?>([^<]*)</annotation>', open(f'{cldr}/{f}', encoding='utf-8').read()):
        cp, tts, text = html.unescape(m.group(1)), m.group(2), html.unescape(m.group(3))
        e = by_bare.get(cp.replace('️', ''))
        if not e: continue
        if tts: names.setdefault(e, text.lower())
        else: keywords[e] += [k.strip().lower() for k in text.split('|')]

def words(s): return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", s.lower())

STOP = set("""a an the and or of to in on at is it i me my we you he she they them us be are was were for with as by this
that so but not do does did can will just than then there their its it's i'm you're our your his her him from into about
over under out off up down if all any some more most very too also only own same such no nor yes ok okay one two get got""".split())
# Keep a few short words people do want emoji for.
KEEP = {"ok", "no", "yes", "up", "one", "two", "100"}

def newness(e):
    """Newer emoji (Unicode 12+ live mostly at U+1FA70 and up) look odd as a first suggestion."""
    pen = 0
    if any(ord(c) >= 0x1FA70 for c in e): pen += 25
    if '\u200d' in e: pen += 8
    return pen

score = collections.defaultdict(lambda: collections.defaultdict(int))
for e, name in catalog:
    nm = names.get(e, name.lower())
    nw = words(nm.replace('flag:', ''))
    kws = keywords.get(e, [])
    for w in set(nw):
        s = 100 if nm == w else 62 + (8 if nw and nw[0] == w else 0)
        score[w][e] = max(score[w][e], s - newness(e))
    for k in kws:
        kw = words(k)
        if len(kw) == 1:
            # A keyword among a few is more central to the emoji than one among many.
            s = 50 + max(0, 12 - len(kws))
            score[kw[0]][e] = max(score[kw[0]][e], s - newness(e))
        else:
            for w in set(kw): score[w][e] = max(score[w][e], 20 - newness(e))

# Common words where people expect particular emoji (checked against what the iOS keyboard offers).
CURATED = {
 "cool": "😎 🆒 🤙", "love": "❤️ 😍 🥰", "happy": "😊 😀 😄", "sad": "😢 😔 😞", "cry": "😢 😭 🥲",
 "crying": "😭 😢", "laugh": "😂 🤣 😆", "laughing": "😂 🤣 😆", "lol": "😂 🤣 😆", "lmao": "🤣 😂",
 "haha": "😂 🤣 😆", "funny": "😂 🤣 😆", "smile": "😊 😀 🙂", "wink": "😉", "kiss": "😘 💋 😗",
 "angry": "😠 😡 🤬", "mad": "😠 😡 🤬", "wow": "😮 🤩 😲", "omg": "😱 😮 🙀", "shocked": "😱 😮 😲",
 "scared": "😱 😨 😰", "tired": "😴 😩 🥱", "sleep": "😴 💤 🛌", "sleepy": "😴 🥱 💤", "sick": "🤒 🤢 🤧",
 "think": "🤔 💭", "thinking": "🤔 💭", "hmm": "🤔", "shh": "🤫", "sorry": "😔 🙏 😞", "please": "🙏 🥺",
 "thanks": "🙏 😊 💕", "thank": "🙏 😊", "hi": "👋 😊", "hello": "👋 😊", "hey": "👋", "bye": "👋 😘",
 "yes": "✅ 👍 👌", "no": "❌ 🙅 👎", "ok": "👌 🆗 👍", "okay": "👌 🆗 👍", "good": "👍 👌 😊", "great": "👍 🙌 😃",
 "awesome": "😎 🙌 🤩", "nice": "👍 👌 😊", "bad": "👎 😞", "perfect": "👌 💯 😍", "yay": "🎉 🙌 😃",
 "congrats": "🎉 🥳 👏", "congratulations": "🎉 🥳 👏", "clap": "👏", "party": "🎉 🥳 🎊", "celebrate": "🎉 🥳 🍾",
 "birthday": "🎂 🎉 🥳", "cake": "🎂 🍰 🧁", "gift": "🎁", "present": "🎁", "christmas": "🎄 🎅 🎁",
 "halloween": "🎃 👻 🦇", "heart": "❤️ 💕 💖", "hearts": "💕 ❤️ 💖", "fire": "🔥", "lit": "🔥 🙌",
 "hot": "🔥 🥵 🌶️", "cold": "🥶 ❄️ 🧊", "strong": "💪", "muscle": "💪", "pray": "🙏", "praying": "🙏",
 "eyes": "👀", "look": "👀", "money": "💰 💵 🤑", "rich": "🤑 💰", "100": "💯", "hundred": "💯",
 "star": "⭐ 🌟 ✨", "sparkle": "✨", "magic": "✨ 🪄 🔮", "rainbow": "🌈", "sun": "☀️ 🌞 😎", "sunny": "☀️ 😎",
 "rain": "🌧️ ☔ 💧", "snow": "❄️ ☃️ 🌨️", "moon": "🌙 🌕 🌝", "night": "🌙 😴 🌃", "morning": "☀️ 🌅 ☕",
 "coffee": "☕", "tea": "🍵 ☕", "beer": "🍺 🍻", "wine": "🍷 🥂", "cheers": "🥂 🍻", "drink": "🍹 🍺 🥤",
 "pizza": "🍕", "burger": "🍔", "food": "🍔 🍕 🍽️", "hungry": "🤤 🍔 🍕", "eat": "🍽️ 😋", "yummy": "😋 🤤",
 "delicious": "😋 🤤", "taco": "🌮", "sushi": "🍣", "icecream": "🍦", "cookie": "🍪", "apple": "🍎 🍏",
 "dog": "🐶 🐕 🐾", "puppy": "🐶 🐕", "cat": "🐱 🐈 😺", "kitty": "🐱 😺", "car": "🚗 🚙", "plane": "✈️",
 "flight": "✈️", "travel": "✈️ 🧳 🌍", "home": "🏠 🏡", "house": "🏠 🏡", "work": "💼 💻", "school": "🏫 📚 🎒",
 "book": "📚 📖", "phone": "📱", "call": "📞 📱", "music": "🎵 🎶 🎧", "song": "🎵 🎶", "dance": "💃 🕺",
 "game": "🎮 🎲", "ball": "⚽ 🏀 🏈", "soccer": "⚽", "basketball": "🏀", "football": "🏈", "baseball": "⚾",
 "run": "🏃 💨", "gym": "💪 🏋️", "beach": "🏖️ 🌊 ☀️", "ocean": "🌊", "flower": "🌸 🌹 🌷", "flowers": "💐 🌸 🌷",
 "rose": "🌹", "tree": "🌳 🌲", "earth": "🌍 🌎 🌏", "world": "🌍 🌎 🌏", "ghost": "👻", "skull": "💀", "dead": "💀 😵",
 "poop": "💩", "devil": "😈", "angel": "😇", "baby": "👶 🍼", "boy": "👦", "girl": "👧", "man": "👨", "woman": "👩",
 "family": "👨‍👩‍👧 👪", "friends": "👯 🤝 💕", "hug": "🤗 🫂", "wave": "👋 🌊", "time": "⏰ ⌛ 🕐", "clock": "⏰ 🕐",
 "idea": "💡", "check": "✅ ✔️", "done": "✅ 👍", "warning": "⚠️", "stop": "🛑 ✋", "rocket": "🚀", "fast": "💨 🏎️ 🚀",
 "win": "🏆 🥇 🎉", "winner": "🏆 🥇", "trophy": "🏆", "crown": "👑", "king": "👑 🤴", "queen": "👑 👸",
 "boom": "💥", "shrug": "🤷", "facepalm": "🤦", "nervous": "😬 😅", "awkward": "😬 😅", "embarrassed": "😳 😅",
 "blush": "😊 ☺️", "bored": "😑 🥱", "confused": "😕 🤔 😵‍💫", "crazy": "🤪 😜", "silly": "🤪 😜 😝",
 "wtf": "🤯 😳", "mindblown": "🤯", "excited": "🤩 😆 🎉", "proud": "🥹 👏 💪", "hope": "🤞 🙏", "luck": "🍀 🤞",
 "lucky": "🍀 🤞", "peace": "✌️ ☮️ 🕊️", "fingers": "🤞", "point": "👉 ☝️", "up": "⬆️ 👆 🆙", "down": "⬇️ 👇",
}

lines = []
for w, picks in CURATED.items():
    picks = [p for p in picks.split() if p in order]
    if not picks: continue
    ranked = {p: 1000 - i for i, p in enumerate(picks)}
    score[w] = ranked
    # The plural follows the hand-picked singular ("dogs" → 🐶 like "dog").
    plural = w[:-1] + "ies" if w.endswith("y") and w[-2:-1] not in "aeiou" else w + ("es" if w.endswith(("s", "x", "ch", "sh")) else "s")
    if plural in score and plural not in CURATED: score[plural] = ranked
for w, cands in score.items():
    if len(w) < 2 or (w in STOP and w not in KEEP and w not in CURATED) or w.isdigit() and w != "100": continue
    best = sorted(cands.items(), key=lambda kv: (-kv[1], order[kv[0]]))
    best = [e for e, s in best if s >= 30][:3]
    if best: lines.append(f"{w}\t{' '.join(best)}")
lines.sort()
open(out_path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(len(lines), 'words')
