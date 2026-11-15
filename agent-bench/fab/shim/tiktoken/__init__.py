"""tiktoken as FHIR-AgentBench's utils load it at import time (it downloads an encoding; the scorer
never counts tokens). An encoding here counts words, so nothing is fetched."""


class _Encoding:
    def encode(self, text, **_):
        return text.split()


def get_encoding(name):
    return _Encoding()
