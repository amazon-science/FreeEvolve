#!/usr/bin/env python3
"""Generate the dummy environment's question sets.

Answers are COMPUTED, so the keys are correct by construction. Train and test
are drawn from the same generators with different seeds, so they are the same
distribution — a fair generalization check.

Sizes are calibrated so a single careful model pass is unreliable (roughly
30-70% correct) while a scaffolded agent that verifies its work can do much
better. That leaves the headroom an evolver needs.

    python3 generate.py          # rewrites train.jsonl and test.jsonl
"""

from __future__ import annotations

import json
import random
import string
from pathlib import Path

HERE = Path(__file__).resolve().parent


def build(seed: int) -> list[dict]:
    r = random.Random(seed)
    q: list[dict] = []

    def add(qid: str, question: str, answer) -> None:
        q.append({"id": qid, "question": question, "answer": str(answer)})

    # --- counting a letter in a long string -------------------------------
    for n, letter in ((700, "c"), (900, "f"), (1100, "b")):
        s = "".join(r.choice("abcdefgh") for _ in range(n))
        add(
            f"count-letter-{n}",
            f"How many times does the letter {letter} appear in this string: "
            f"{s}? Answer with a number only.",
            s.count(letter),
        )

    # --- counting a bigram ------------------------------------------------
    s = "".join(r.choice("abcd") for _ in range(500))
    add(
        "count-bigram",
        f"How many times does the two-letter sequence ab appear in this "
        f"string (overlapping occurrences count): {s}? Answer with a number only.",
        sum(s[i:i + 2] == "ab" for i in range(len(s) - 1)),
    )

    # --- nth character of a long string -----------------------------------
    for n, pos in ((600, 417), (1200, 863)):
        s = "".join(r.choice(string.ascii_lowercase) for _ in range(n))
        add(
            f"nth-char-{n}",
            f"What is the {pos}th character of this string: {s}? "
            f"Answer with the single lowercase letter only.",
            s[pos - 1],
        )

    # --- distinct letters in a string over a restricted alphabet ----------
    alpha = "".join(r.sample(string.ascii_lowercase, 18))
    s = "".join(r.choice(alpha) for _ in range(120))
    add(
        "distinct-letters",
        f"How many distinct letters appear in this string: {s}? "
        f"Answer with a number only.",
        len(set(s)),
    )

    # --- longest / second longest word in a long list ---------------------
    for n in (120, 200):
        words = _unique_length_words(r, n)
        add(
            f"longest-{n}",
            f"Which of these words is the longest: {', '.join(words)}? "
            f"Answer with the word only.",
            max(words, key=len),
        )
    words = _unique_length_words(r, 100)
    add(
        "second-longest",
        f"Which of these words is the second longest: {', '.join(words)}? "
        f"Answer with the word only.",
        sorted(words, key=len, reverse=True)[1],
    )

    # --- word frequency in a long text ------------------------------------
    for n, target in ((500, "zeta"), (800, "delta")):
        vocab = "alpha beta gamma delta epsilon zeta eta theta".split()
        text = " ".join(r.choice(vocab) for _ in range(n))
        add(
            f"word-freq-{n}",
            f"How many times does the word {target} appear in this text: "
            f"{text}? Answer with a number only.",
            text.split().count(target),
        )

    # --- how many words in a list contain a letter ------------------------
    words = ["".join(r.choice(string.ascii_lowercase) for _ in range(r.randint(4, 12))) for _ in range(60)]
    add(
        "count-words-containing",
        f"In this list of words, how many contain the letter q: "
        f"{', '.join(words)}? Answer with a number only.",
        sum("q" in w for w in words),
    )

    # --- sums and order statistics ----------------------------------------
    for n in (100, 180):
        nums = [r.randint(1000, 9999) for _ in range(n)]
        add(
            f"sum-{n}",
            f"What is the sum of these numbers: {', '.join(map(str, nums))}? "
            f"Answer with the number only.",
            sum(nums),
        )
    nums = [r.randint(1, 99999) for _ in range(41)]
    add(
        "median-41",
        f"What is the median of these numbers: {', '.join(map(str, nums))}? "
        f"Answer with the number only.",
        sorted(nums)[20],
    )
    nums = [r.randint(1, 99999) for _ in range(60)]
    add(
        "seventh-largest",
        f"Among these numbers, what is the seventh largest: "
        f"{', '.join(map(str, nums))}? Answer with the number only.",
        sorted(nums)[-7],
    )
    nums = [r.randint(100, 999) for _ in range(50)]
    add(
        "count-above-mean",
        f"How many of these numbers are strictly greater than their own "
        f"average: {', '.join(map(str, nums))}? Answer with a number only.",
        sum(x > sum(nums) / len(nums) for x in nums),
    )

    # --- long arithmetic chains -------------------------------------------
    for n_steps in (18, 24):
        start = r.randint(1000, 9999)
        v, steps = start, []
        while len(steps) < n_steps:
            op = r.choice(["multiply by", "add", "subtract", "divide by"])
            if op == "multiply by":
                x = r.randint(2, 9); nv = v * x
            elif op == "add":
                x = r.randint(100, 99999); nv = v + x
            elif op == "subtract":
                x = r.randint(100, 9999); nv = v - x
            else:
                x = r.randint(2, 9); nv = v // x
            if nv <= 0 or nv > 10 ** 12:
                continue
            v = nv
            steps.append(f"{op} {x}")
        add(
            f"arith-chain-{n_steps}",
            f"Start with {start}. Then " + ", then ".join(steps) +
            ". Every division is integer division, discarding any remainder. "
            "What is the result? Answer with the number only.",
            v,
        )

    # --- caesar decode ----------------------------------------------------
    msg = " ".join(
        r.choice(
            "the agent must verify every intermediate answer before it "
            "reports a final result to avoid careless mistakes".split()
        )
        for _ in range(14)
    )
    shift = r.randint(3, 20)
    enc = "".join(
        chr((ord(c) - 97 + shift) % 26 + 97) if c.isalpha() else c for c in msg
    )
    add(
        "caesar",
        f"This message was encrypted by shifting each letter forward {shift} "
        f"places in the alphabet, wrapping around from z to a: {enc}. What is "
        f"the original message? Answer with the decoded message only, lowercase.",
        msg,
    )

    # --- nesting depth ----------------------------------------------------
    expr, depth, maxd = [], 0, 0
    for _ in range(70):
        if depth > 0 and r.random() < 0.45:
            expr.append(")"); depth -= 1
        else:
            expr.append("("); depth += 1; maxd = max(maxd, depth)
        if r.random() < 0.3:
            expr.append(r.choice(string.ascii_lowercase))
    expr.extend(")" * depth)
    add(
        "paren-depth",
        f"What is the maximum nesting depth of parentheses in this "
        f"expression: {''.join(expr)}? Answer with a number only.",
        maxd,
    )

    return q


def _unique_length_words(r: random.Random, n: int) -> list[str]:
    """n random words whose top three lengths are strictly distinct.

    Built by construction rather than rejection sampling: the filler words are
    capped below the three planted lengths, so `longest` and `second longest`
    each have exactly one correct answer.
    """
    def word(length: int) -> str:
        return "".join(r.choice(string.ascii_lowercase) for _ in range(length))

    words = [word(r.randint(3, 12)) for _ in range(n - 3)]
    words += [word(16), word(15), word(14)]
    r.shuffle(words)
    return words


def main() -> None:
    for split, seed in (("train", 1729), ("test", 8191)):
        qs = build(seed)
        path = HERE / f"{split}.jsonl"
        path.write_text("".join(json.dumps(q) + "\n" for q in qs))
        print(f"{split}: {len(qs)} questions -> {path}")


if __name__ == "__main__":
    main()
