---
title: "Part IV — Knowing You're Right"
parent: "Guide"
nav_order: 4
has_children: true
---

# Part IV — Knowing You're Right

{% assign part_chapters = site.html_pages | where: "parent", page.title | sort: "nav_order" %}
<ul class="part-chapters">
{% for ch in part_chapters %}  <li><a href="{{ ch.url | relative_url }}">{{ ch.title }}</a></li>
{% endfor %}</ul>
