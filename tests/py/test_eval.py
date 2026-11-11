"""Accuracy of the production path on the hand-written evaluation set (real model).

``data/langid_evalset.json`` holds 200 whole-text items and 32 mixed paragraphs (105 gold
sentences); ``data/langid_evalset_heldout.json`` holds 8 paragraphs written after the
smoothing parameters were tuned. The thresholds are the measured values minus a margin.
"""

import json
import os
import time

# Test framework.
import pytest

# Pipeline modules under test.
import htts_langid
import htts_markup
import htts_pipeline
# Splitting is checked together with labelling.
import htts_split

# Evaluation data and the language sets used in the thresholds.
DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
FIVE = ("de", "en", "fr", "es", "it")
SEVEN = FIVE + ("pt", "nl")


def load(name):
    """Load one evaluation file.

    Args:
        name: File name inside tests/py/data.

    Returns:
        The parsed JSON document.
    """
    # The files are UTF-8 JSON written by the research prototype.
    with open(os.path.join(DATA_DIR, name), encoding="utf-8") as handle:
        return json.load(handle)


def whole_text_accuracy(items, allowed):
    """Share of whole-text items whose detected language equals the gold label.

    Args:
        items: Eval items with ``text`` and ``gold``.
        allowed: Allowed languages.

    Returns:
        Accuracy between 0 and 1 over the items whose gold language is allowed.
    """
    # Only items in an allowed language can be right.
    scored = [item for item in items if item["gold"] in allowed]
    hits = sum(htts_pipeline.detect(item["text"], allowed, allowed[0]) == item["gold"]
               for item in scored)
    return hits / len(scored)


def sentence_labels(sentences, allowed):
    """Label gold sentences through the production split and label path.

    Args:
        sentences: Gold sentence dicts of one paragraph.
        allowed: Allowed languages.

    Returns:
        One label per gold sentence (None when the sentence cannot be located).
    """
    # Join like running text, then split, label and map back by the sentence start.
    text = " ".join(sentence["text"] for sentence in sentences)
    pieces = htts_split.split_sentences(htts_markup.normalize_text(text))
    labels = htts_langid.label_sentences(pieces, allowed, allowed[0])
    found = []
    for gold in sentences:
        # A piece belongs to the gold sentence when it starts with its first characters.
        head = gold["text"][:12]
        votes = [label for piece, label in zip(pieces, labels) if head in piece]
        found.append(votes[0] if votes else None)
    return found


def mixed_accuracy(paragraphs, allowed):
    """Per-sentence accuracy over mixed-language paragraphs.

    Args:
        paragraphs: Eval paragraphs with a ``sentences`` list.
        allowed: Allowed languages.

    Returns:
        Accuracy between 0 and 1.
    """
    # Count correct labels over all sentences of paragraphs in allowed languages.
    total = hits = 0
    for paragraph in paragraphs:
        sentences = paragraph["sentences"]
        # Paragraphs with languages outside the allow-list cannot be scored.
        if any(sentence["gold"] not in allowed for sentence in sentences):
            continue
        for gold, label in zip(sentences, sentence_labels(sentences, allowed)):
            # Count one hit per correctly labelled sentence.
            total += 1
            hits += label == gold["gold"]
    return hits / total


@pytest.fixture(scope="module")
def evalset(lid_model):
    """Load the development evaluation set (skips without the model).

    Args:
        lid_model: Fixture that skips without the model.

    Returns:
        The parsed development set.
    """
    # The fixture dependency ensures the real model is present.
    return load("langid_evalset.json")


def test_whole_text_accuracy_with_five_voices(evalset):
    """Five installed voices: at least 99 % of 177 items (measured 100 %).

    Args:
        evalset: The development set.

    Returns:
        None.
    """
    # The realistic install has de, en, fr, es, it.
    assert whole_text_accuracy(evalset["whole"], FIVE) >= 0.99


def test_whole_text_accuracy_with_seven_voices(evalset):
    """Seven allowed languages: at least 98 % of 200 items (measured 99.5 %).

    Args:
        evalset: The development set.

    Returns:
        None.
    """
    # pt and nl are added, which makes some short German phrases ambiguous.
    assert whole_text_accuracy(evalset["whole"], SEVEN) >= 0.98


def test_mixed_paragraph_accuracy_on_the_development_set(evalset):
    """Per-sentence accuracy on 96 development sentences is at least 95 % (measured 97 %).

    Args:
        evalset: The development set.

    Returns:
        None.
    """
    # Known misses: short foreign sentences inside a paragraph are absorbed.
    assert mixed_accuracy(evalset["mixed"], FIVE) >= 0.95


def test_mixed_paragraph_accuracy_on_the_heldout_set(lid_model):
    """The held-out paragraphs are labelled 100 % correctly.

    Args:
        lid_model: Fixture that skips without the model.

    Returns:
        None.
    """
    # These paragraphs were never used to tune the smoothing parameters.
    assert mixed_accuracy(load("langid_evalset_heldout.json")["mixed"], FIVE) == 1.0


def test_prepare_on_two_kilobytes_is_fast_in_process(lid_model, number_words):
    """In-process preparation of 2 KB of mixed text stays well under half a second.

    Args:
        lid_model: Fixture that skips without the model.
        number_words: Fixture that skips without num2words.

    Returns:
        None.
    """
    # Build about 2 KB from the held-out paragraphs.
    paragraphs = load("langid_evalset_heldout.json")["mixed"]
    text = " ".join(s["text"] for p in paragraphs for s in p["sentences"])[:2000]
    # Warm the lazy model load once, then time a second run.
    htts_pipeline.prepare(text, FIVE, "de")
    start = time.perf_counter()
    htts_pipeline.prepare(text, FIVE, "de")
    assert time.perf_counter() - start < 0.5
