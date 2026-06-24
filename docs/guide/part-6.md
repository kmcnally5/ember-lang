---
title: "Part VI — Things People See"
parent: "Guide"
nav_order: 6
has_children: true
---

# Part VI — Things People See

{% assign part_chapters = site.html_pages | where: "parent", page.title | sort: "nav_order" %}
<ul class="part-chapters">
{% for ch in part_chapters %}  <li><a href="{{ ch.url | relative_url }}">{{ ch.title }}</a></li>
{% endfor %}</ul>
