"""Language identification for a text-to-speech reader: fastText plus sentence smoothing.

The classifier (fastText ``lid.176.ftz``) scores every sentence over only the languages
that have a voice. A Viterbi smoothing pass then keeps short or doubtful sentences
(``Okay.``, a name, a loanword) in the surrounding language, so one English word never
flips a German paragraph. The library and the model load lazily; with a single allowed
language nothing is loaded at all.
"""

# Standard-library modules only; fastText itself is imported lazily.
from __future__ import annotations

import math
import os
import re

# Name of the environment variable that points at the model file.
MODEL_ENV_VAR = "HTTS_LID_MODEL"
# File name of the fastText language-identification model.
MODEL_FILE_NAME = "lid.176.ftz"
# Prefix fastText puts in front of every language label.
LABEL_PREFIX = "__label__"
# Number of fastText labels requested so every allowed language gets a probability.
ALL_LABELS = 176
# Sentence length (letters) at which classifier evidence counts with full weight.
FULL_EVIDENCE_LETTERS = 25
# Cost (log-probability units) of switching language between adjacent sentences.
SWITCH_PENALTY = 1.75
# Floor for probabilities so a zero score cannot dominate the search.
MIN_PROBABILITY = 1e-3
# Placeholders the markup stage inserts; they are English words without language signal.
STAND_INS = re.compile(r"\((?:link|email)\)")
# Everything that is not a letter, apostrophe or hyphen carries no language signal.
NON_LETTER = re.compile(r"[^\w'’\-]|[\d_]+")


class LanguageModelUnavailable(RuntimeError):
    """Raised when fastText or its model file is missing."""


class SentenceEvidence:
    """Classification evidence for one sentence.

    Attributes:
        scores: Probability per allowed language (empty without letters).
        letters: Number of alphabetic characters, a proxy for evidence strength.
    """

    __slots__ = ("scores", "letters")

    def __init__(self, scores: dict[str, float], letters: int) -> None:
        """Store the evidence fields.

        Args:
            scores: Probability per allowed language.
            letters: Alphabetic character count.

        Returns:
            None.
        """
        # Plain attributes keep import time low compared to dataclasses.
        self.scores = scores
        self.letters = letters


def model_search_paths() -> list[str]:
    """List the places the model file may live, best first.

    Returns:
        Candidate paths: the environment override, the user data dir, then /usr/share.
    """
    # An explicit override wins over every default location.
    override = os.environ.get(MODEL_ENV_VAR, "")
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    # The user-space install comes before the system-wide package location.
    user_copy = os.path.join(data_home, "hyprland-tts", "langid", MODEL_FILE_NAME)
    system_copy = os.path.join("/usr/share/hyprland-tts", MODEL_FILE_NAME)
    return [path for path in (override, user_copy, system_copy) if path]


def find_model_path() -> str:
    """Locate the fastText model file.

    Returns:
        Path of the first existing candidate.

    Raises:
        LanguageModelUnavailable: If no candidate exists.
    """
    # Return the first candidate that is a regular file.
    for candidate in model_search_paths():
        if os.path.isfile(candidate):
            return candidate
    # Reaching this line means no candidate file exists.
    raise LanguageModelUnavailable(f"{MODEL_FILE_NAME} not found (set {MODEL_ENV_VAR})")


# Process-wide cache so the model is loaded at most once.
_MODEL_CACHE: list = []


def load_model():
    """Load the fastText model once per process.

    Returns:
        The loaded fastText model object.

    Raises:
        LanguageModelUnavailable: If the library or the model file is missing.
    """
    # Reuse the model when it was loaded before.
    if _MODEL_CACHE:
        return _MODEL_CACHE[0]
    # The import is lazy so single-language runs never pay for it.
    try:
        import fasttext
    except ImportError as error:
        raise LanguageModelUnavailable("python module 'fasttext' is not installed") from error
    # Load the model and remember it.
    _MODEL_CACHE.append(fasttext.load_model(find_model_path()))
    return _MODEL_CACHE[0]


def clean_for_detection(text: str) -> str:
    """Strip placeholders, digits and symbols that carry no language signal.

    Args:
        text: One sentence.

    Returns:
        Whitespace-normalised text with letters only (single line).
    """
    # Placeholders like (link) are English words and would bias the result.
    without_stand_ins = STAND_INS.sub(" ", text)
    # Digits and symbols are removed, whitespace collapses to single spaces.
    collapsed = " ".join(NON_LETTER.sub(" ", without_stand_ins).split())
    # Shouted ALL CAPS text is lowered so it is not scored as abbreviations.
    return collapsed.lower() if collapsed.isupper() else collapsed


def fasttext_scores(text: str, allowed: tuple[str, ...]) -> dict[str, float]:
    """Score text with fastText and renormalise over the allowed languages.

    Args:
        text: Cleaned single-line text.
        allowed: Allowed ISO 639-1 codes.

    Returns:
        Probability per allowed language (empty if the model gives them no mass).
    """
    # Ask for the full ranking so every allowed language has a probability.
    labels, probabilities = load_model().predict(text, k=ALL_LABELS)
    raw = {label[len(LABEL_PREFIX):]: min(prob, 1.0) for label, prob in zip(labels, probabilities)}
    # Restrict to the allowed set and renormalise so the values sum to one.
    restricted = {lang: raw.get(lang, 0.0) for lang in allowed}
    total = sum(restricted.values())
    return {lang: prob / total for lang, prob in restricted.items()} if total > 0 else {}


def analyse_sentence(sentence: str, allowed: tuple[str, ...], scorer) -> SentenceEvidence:
    """Collect language evidence for one sentence.

    Args:
        sentence: Sentence text.
        allowed: Allowed ISO 639-1 codes.
        scorer: Function mapping (cleaned text, allowed) to probabilities.

    Returns:
        Evidence with empty scores when the sentence has no letters.
    """
    # Only the cleaned letters are classified so numbers and markup cannot sway it.
    cleaned = clean_for_detection(sentence)
    letters = sum(char.isalpha() for char in cleaned)
    # A sentence without letters skips the classifier entirely.
    return SentenceEvidence(scorer(cleaned, allowed) if letters else {}, letters)


def emission_scores(evidence: SentenceEvidence, states: list[str]) -> dict[str, float]:
    """Compute how well each language explains a sentence (log domain).

    Args:
        evidence: Evidence for one sentence.
        states: Candidate languages.

    Returns:
        Log-probability-like score per language; short sentences are flattened toward zero.
    """
    # Short text is unreliable, so its evidence is scaled down by length.
    weight = min(1.0, evidence.letters / FULL_EVIDENCE_LETTERS)
    # The probability floor stops one near-zero value from dominating the search.
    return {
        lang: weight * math.log(max(evidence.scores.get(lang, 0.0), MIN_PROBABILITY))
        for lang in states
    }


def viterbi_step(
    previous: dict[str, float], emission: dict[str, float]
) -> tuple[dict[str, float], dict[str, str]]:
    """Advance the Viterbi search by one sentence.

    Args:
        previous: Best path score ending in each language at the previous sentence.
        emission: Emission scores of the current sentence.

    Returns:
        New best scores per language and the best predecessor language for each.
    """
    # For each target language pick the cheapest predecessor; staying is free.
    scores: dict[str, float] = {}
    pointers: dict[str, str] = {}
    for lang, emit in emission.items():
        # Arriving from a different language costs the switch penalty.
        arrival = {p: previous[p] - (0 if p == lang else SWITCH_PENALTY) for p in previous}
        best_previous = max(arrival, key=arrival.get)
        # Remember the winning score and where it came from.
        scores[lang] = arrival[best_previous] + emit
        pointers[lang] = best_previous
    return scores, pointers


def smooth_labels(
    evidence: list[SentenceEvidence], allowed: tuple[str, ...], default_lang: str
) -> list[str]:
    """Pick one language per sentence by minimising evidence loss plus switching cost.

    Args:
        evidence: Evidence per sentence in text order.
        allowed: Candidate languages.
        default_lang: Language that wins exact ties.

    Returns:
        One language code per sentence.
    """
    # Order the states so the default language wins exact ties.
    states = sorted(allowed, key=lambda lang: lang != default_lang)
    if not evidence:
        return []
    # Forward pass: extend every path by one sentence and keep the back-pointers.
    scores = emission_scores(evidence[0], states)
    history = []
    for item in evidence[1:]:
        # Extend every path by one sentence and keep the pointers for the way back.
        scores, pointers = viterbi_step(scores, emission_scores(item, states))
        history.append(pointers)
    # Backward pass: follow the pointers from the best final state.
    labels = [max(states, key=lambda lang: scores[lang])]
    for pointers in reversed(history):
        labels.append(pointers[labels[-1]])
    return labels[::-1]


def parse_language_list(csv: str) -> tuple[str, ...]:
    """Parse and validate a comma-separated list of ISO 639-1 codes.

    Args:
        csv: For example ``"de,en"``.

    Returns:
        Unique lowercase codes in order.

    Raises:
        ValueError: If a code is not two or three lowercase letters or the list is empty.
    """
    # Lowercase, strip and deduplicate while keeping the order.
    codes = [code.strip().lower() for code in csv.split(",") if code.strip()]
    unique = tuple(dict.fromkeys(codes))
    # Only plain language codes are accepted (no paths, no shell syntax).
    for code in unique:
        if not re.fullmatch(r"[a-z]{2,3}", code):
            raise ValueError(f"invalid language code: {code!r}")
    # An empty list has no language to work with.
    if not unique:
        raise ValueError("at least one language is required")
    return unique


def label_sentences(
    sentences: list[str], allowed: tuple[str, ...], default_lang: str, scorer=None
) -> list[str]:
    """Assign a language to every sentence.

    Args:
        sentences: Sentences in text order.
        allowed: Languages that have a voice.
        default_lang: Language for sentences without evidence.
        scorer: Optional scoring function (defaults to fastText); injected by tests.

    Returns:
        One language per sentence, always a member of ``allowed``.
    """
    # With a single candidate there is nothing to classify and no model to load.
    if len(allowed) == 1:
        return [allowed[0]] * len(sentences)
    # Score every sentence, then smooth over the whole text.
    active_scorer = scorer or fasttext_scores
    evidence = [analyse_sentence(text, allowed, active_scorer) for text in sentences]
    return smooth_labels(evidence, allowed, default_lang)


def dominant_language(
    sentences: list[str], labels: list[str], default_lang: str
) -> str:
    """Return the language that covers the most characters.

    Args:
        sentences: Sentences in text order.
        labels: Language per sentence.
        default_lang: Returned when there is no text.

    Returns:
        The heaviest language; ties go to the language seen first.
    """
    # Weigh each language by the visible characters of its sentences.
    weight: dict[str, int] = {}
    for sentence, label in zip(sentences, labels):
        weight[label] = weight.get(label, 0) + len(sentence.strip())
    return max(weight, key=weight.get) if weight else default_lang
