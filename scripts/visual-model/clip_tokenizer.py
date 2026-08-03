"""Small NumPy-only OpenAI CLIP byte-BPE tokenizer.

Algorithm adapted from OpenAI CLIP's MIT-licensed tokenizer (Copyright 2021
OpenAI) and kept deliberately dependency-light for Passage's local bridge.
"""

from __future__ import annotations

from functools import lru_cache
import gzip
import html
from pathlib import Path
from typing import Iterable

import ftfy
import numpy as np
import regex


@lru_cache()
def bytes_to_unicode() -> dict[int, str]:
    values = (
        list(range(ord("!"), ord("~") + 1))
        + list(range(ord("¡"), ord("¬") + 1))
        + list(range(ord("®"), ord("ÿ") + 1))
    )
    characters = values[:]
    offset = 0
    for byte in range(256):
        if byte not in values:
            values.append(byte)
            characters.append(256 + offset)
            offset += 1
    return dict(zip(values, (chr(value) for value in characters)))


def pairs(word: tuple[str, ...]) -> set[tuple[str, str]]:
    return set(zip(word, word[1:]))


def clean(text: str) -> str:
    value = ftfy.fix_text(text)
    value = html.unescape(html.unescape(value))
    return " ".join(value.strip().split()).lower()


class SimpleTokenizer:
    def __init__(self, bpe_path: Path, context_length: int = 32) -> None:
        self.byte_encoder = bytes_to_unicode()
        with gzip.open(bpe_path, "rt", encoding="utf-8") as stream:
            merge_lines = stream.read().split("\n")
        merges = [tuple(item.split()) for item in merge_lines[1 : 49152 - 256 - 2 + 1]]
        vocabulary = list(self.byte_encoder.values())
        vocabulary.extend(value + "</w>" for value in self.byte_encoder.values())
        vocabulary.extend("".join(merge) for merge in merges)
        special_tokens = ["<start_of_text>", "<end_of_text>"]
        vocabulary.extend(special_tokens)
        self.encoder = dict(zip(vocabulary, range(len(vocabulary))))
        self.bpe_ranks = dict(zip(merges, range(len(merges))))
        self.cache = {token: token for token in special_tokens}
        self.pattern = regex.compile(
            "|".join(special_tokens)
            + r"|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+",
            regex.IGNORECASE,
        )
        self.start_token = self.encoder[special_tokens[0]]
        self.end_token = self.encoder[special_tokens[1]]
        self.context_length = context_length

    def bpe(self, token: str) -> str:
        if token in self.cache:
            return self.cache[token]
        word = tuple(token[:-1]) + (token[-1] + "</w>",)
        candidates = pairs(word)
        if not candidates:
            return token + "</w>"
        while True:
            bigram = min(candidates, key=lambda pair: self.bpe_ranks.get(pair, float("inf")))
            if bigram not in self.bpe_ranks:
                break
            first, second = bigram
            merged: list[str] = []
            index = 0
            while index < len(word):
                try:
                    match = word.index(first, index)
                    merged.extend(word[index:match])
                    index = match
                except ValueError:
                    merged.extend(word[index:])
                    break
                if word[index] == first and index < len(word) - 1 and word[index + 1] == second:
                    merged.append(first + second)
                    index += 2
                else:
                    merged.append(word[index])
                    index += 1
            word = tuple(merged)
            if len(word) == 1:
                break
            candidates = pairs(word)
        result = " ".join(word)
        self.cache[token] = result
        return result

    def encode(self, text: str) -> list[int]:
        result: list[int] = []
        for match in regex.findall(self.pattern, clean(text)):
            encoded = "".join(self.byte_encoder[byte] for byte in match.encode("utf-8"))
            result.extend(self.encoder[item] for item in self.bpe(encoded).split(" "))
        return result

    def __call__(self, texts: Iterable[str]) -> np.ndarray:
        rows = []
        for text in texts:
            tokens = [self.start_token, *self.encode(text), self.end_token]
            if len(tokens) > self.context_length:
                tokens = tokens[: self.context_length]
                tokens[-1] = self.end_token
            tokens.extend([0] * (self.context_length - len(tokens)))
            rows.append(tokens)
        return np.asarray(rows, dtype=np.int32)
