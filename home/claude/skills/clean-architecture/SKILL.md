---
name: clean-architecture
description: Clean architecture, SOLID, pragmatic refactoring, and code quality guide. Focuses on minimal complexity, testability, separation of concerns, and preventing over-engineering.
---

# Clean Architecture & Pragmatic Refactoring

Zestaw reguł i heurystyk do pisania trwałego, czytelnego i łatwego w utrzymaniu kodu bez popadania w nadmierną abstrakcję (over-engineering).

## 1. Fundamenty
- **Functional Core, Imperative Shell:**
  - Logikę biznesową i przetwarzanie danych realizuj jako czyste, deterministyczne funkcje (łatwe do testowania bez mocków).
  - Skutki uboczne (I/O, operacje na plikach, zapytania sieciowe, modyfikacje bazy) izoluj na brzegach aplikacji.
- **Zasada Pojedynczej Odpowiedzialności (SRP):**
  - Klasa, moduł lub funkcja powinna mieć tylko jeden powód do zmiany.
- **Pragmatyzm ponad Dogmatyzm:**
  - Nie twórz fabryk fabryk, zbędnych adapterów ani interfejsów z tylko jedną implementacją, chyba że wymusza to testowalność lub wymiana silnika w czasie rzeczywistym.

## 2. Refaktoryzacja i Eliminacja Długu Technicznego
- **Boy Scout Rule:** Pozostaw edytowany plik w lepszym stanie, niż go zastałeś (popraw nazewnictwo zmiennych, usuń martwy kod).
- **Zmniejszanie zagnieżdżenia:** Stosuj instrukcje strażnicze (*guard clauses*) i wczesny powrót (*early return*) zamiast głęboko zagnieżdżonych bloków `if/else`.
- **Zwarte diffy:** Zmiany wprowadzaj w logicznych, małych porcjach.
