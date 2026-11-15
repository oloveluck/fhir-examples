"""litellm.exceptions as FHIR-AgentBench imports it (the scorer catches nothing from it)."""


class BadRequestError(Exception):
    pass
