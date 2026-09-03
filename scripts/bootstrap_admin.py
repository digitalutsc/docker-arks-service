"""Create the stack's administrator account, or leave an existing one alone.

Piped into `manage.py shell` by `make admin`, so it runs inside the web
container with Django already configured. The credentials arrive as
environment variables set on that one exec call: they are not part of the
image and not part of the service definition in docker-compose.yml.
"""

import os
import sys

from django.contrib.auth import get_user_model

username = os.environ.get("DJANGO_SUPERUSER_USERNAME", "").strip()
email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "").strip()
password = os.environ.get("DJANGO_SUPERUSER_PASSWORD", "")

if not username or not password:
    sys.stderr.write(
        "DJANGO_SUPERUSER_USERNAME and DJANGO_SUPERUSER_PASSWORD must both be "
        "set in .env. Run `make env` to generate the password.\n"
    )
    sys.exit(1)

User = get_user_model()
user = User.objects.filter(username=username).first()

if user is None:
    User.objects.create_superuser(username=username, email=email, password=password)
    print(f"Created administrator {username!r} with password {password!r}.")
    print("A superuser is automatically an Admin in the staff interface.")
else:
    # The password is deliberately left as it is. Re-running `make install`
    # should not reset an account whose password someone has since changed.
    restored = [
        field
        for field in ("is_active", "is_staff", "is_superuser")
        if not getattr(user, field)
    ]
    if restored:
        for field in restored:
            setattr(user, field, True)
        user.save(update_fields=restored)
        print(f"Administrator {username!r} already existed; restored {', '.join(restored)}.")
    else:
        print(f"Administrator {username!r} already exists; its own password still stands.")
