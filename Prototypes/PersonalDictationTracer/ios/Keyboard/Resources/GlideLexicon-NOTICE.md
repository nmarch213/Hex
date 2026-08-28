# Experimental English glide lexicon notices

Hex's personal iOS keyboard prototype includes a derived subset of SymSpell's
`frequency_dictionary_en_82_765.txt` from commit
`c239062ae02961df18ab7da1671d01b4388204e0`:

- Source: <https://github.com/wolfgarbe/SymSpell/blob/c239062ae02961df18ab7da1671d01b4388204e0/SymSpell/frequency_dictionary_en_82_765.txt>
- Source SHA-256: `c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b`
- Changes made by Hex: stripped the UTF-8 BOM, retained unique lowercase ASCII
  words with positive integer counts, sorted by descending count with a stable
  lexical tie-break, and retained the first 20,000 entries. Comments identifying
  the generated prototype resource were added. The derivation is implemented by
  `generate-glide-lexicon.sh` at the prototype root.
- Generated SHA-256: recorded in `english-glide-frequency.txt.sha256`.

SymSpell documents this frequency dictionary as the intersection of Google
Books Ngram frequencies and the SCOWL word list, with additional filtering.
The resource is therefore not described as MIT-only.

- SymSpell is copyright Wolf Garbe and distributed under the MIT License. The
  complete notice is bundled in `GlideLexiconNotices/SymSpell-MIT.txt`.
- Google Books Ngram data is attributed to Google Books Ngram Viewer and made
  available under CC BY 3.0. Source: <https://books.google.com/ngrams/info>.
  License: <https://creativecommons.org/licenses/by/3.0/>. The complete license
  text is bundled in `GlideLexiconNotices/CC-BY-3.0.txt`.
- SCOWL v1 is copyright Kevin Atkinson and its named upstream contributors. Its
  complete copyright, source, permission, and disclaimer notices are bundled in
  `GlideLexiconNotices/SCOWL-v1-Copyright.txt`. Source:
  <https://github.com/en-wl/wordlist/blob/v1/scowl/Copyright>.

This data is selected for an internal prototype. The Creative Commons
anti-technological-measures terms and App Store FairPlay remain unresolved for
public distribution; obtain a license review or replace the resource before a
public App Store release.
