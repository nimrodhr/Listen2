"""LLM client for OpenAI API."""

from __future__ import annotations

import json
import logging
import time
from typing import Optional

logger = logging.getLogger("listen.intelligence.llm_client")


class LLMClient:
    """Interface for text generation via OpenAI."""

    def __init__(
        self,
        api_key: str,
        model: str,
    ) -> None:
        self.api_key = api_key
        self.model = model

        self._openai_client = None
        logger.info(f"LLM client created for model={model}")

    def _get_openai_client(self):
        if self._openai_client is None:
            from openai import AsyncOpenAI

            self._openai_client = AsyncOpenAI(api_key=self.api_key)
            logger.debug("AsyncOpenAI client initialized")
        return self._openai_client

    async def complete(
        self,
        prompt: str,
        system: Optional[str] = None,
        json_mode: bool = False,
        max_tokens: int = 1024,
    ) -> str:
        """Generate a completion using OpenAI."""
        client = self._get_openai_client()

        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        kwargs = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
        }
        if json_mode:
            kwargs["response_format"] = {"type": "json_object"}

        start = time.monotonic()
        try:
            response = await client.chat.completions.create(**kwargs)
            elapsed_ms = (time.monotonic() - start) * 1000
            usage = response.usage
            logger.info(
                f"LLM completion: model={self.model}, "
                f"latency={elapsed_ms:.0f}ms, "
                f"tokens={usage.total_tokens if usage else 'N/A'}"
            )
            return response.choices[0].message.content or ""
        except Exception as e:
            elapsed_ms = (time.monotonic() - start) * 1000
            logger.error(
                f"LLM completion failed: model={self.model}, "
                f"latency={elapsed_ms:.0f}ms, error={e}",
                exc_info=True,
            )
            raise


def create_llm_client(
    model_name: str,
    openai_api_key: str = "",
) -> LLMClient:
    """Create an LLM client for the given model."""
    if not openai_api_key:
        raise ValueError("OpenAI API key is required")
    return LLMClient(api_key=openai_api_key, model=model_name)
