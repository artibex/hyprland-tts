"""CJK support of the text pipeline: sentences, chunk sizes and language labels (real model)."""

import htts_pipeline
import htts_split

# Three sentences each in Chinese, Japanese and Korean, written without any space.
CHINESE = "今天天气很好。我们去公园散步吧！你觉得怎么样？"
JAPANESE = "今日はとても天気が良いです。公園へ散歩に行きましょう。どう思いますか？"
KOREAN = "오늘은 날씨가 아주 좋습니다. 우리 공원에 산책하러 갑시다. 어떻게 생각하세요?"
ALLOWED = ("de", "en", "zh", "ja", "ko")


def test_each_cjk_language_is_split_into_short_chunks_with_its_own_label(lid_model):
    """Chinese, Japanese and Korean text yields several short, correctly labelled chunks.

    Args:
        lid_model: Fixture that skips without the fastText model.

    Returns:
        None.
    """
    for text, expected in ((CHINESE, "zh"), (JAPANESE, "ja"), (KOREAN, "ko")):
        chunks = htts_pipeline.prepare(text, ALLOWED, "en")
        # More than one chunk (the text has three sentences) and every one is labelled correctly.
        assert len(chunks) >= 2, text
        assert {lang for lang, _ in chunks} == {expected}, (text, chunks)
        # No chunk exceeds the CJK limit, so synthesis time per chunk stays bounded.
        assert all(len(chunk) <= htts_split.MAX_CHUNK_CJK for _, chunk in chunks)


def test_mixed_cjk_and_latin_paragraph_keeps_the_languages_apart(lid_model):
    """A paragraph that alternates Chinese and English never mixes both in one chunk.

    Args:
        lid_model: Fixture that skips without the fastText model.

    Returns:
        None.
    """
    # A single short sentence would be smoothed into its neighbours, so three English ones are used.
    english = (" This paragraph is written in English. It has several sentences. "
               "The smoothing must keep them. ")
    text = CHINESE + english + JAPANESE
    chunks = htts_pipeline.prepare(text, ALLOWED, "en")
    # The languages appear in reading order and each chunk has exactly one label.
    labels = [lang for lang, _ in chunks]
    assert "en" in labels and "zh" in labels and "ja" in labels
    assert labels.index("zh") < labels.index("en") < labels.index("ja")
