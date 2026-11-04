"""Create the stack's administrator account if it is absent; never touch an existing one.

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
    print(f"Created administrator {username!r} with password: {password}")
    print("A superuser is automatically an Admin in the staff interface.")
else:
    # Left exactly as it is: no password reset, and no re-enabling or
    # re-promoting either. An account someone has since disabled, demoted or
    # given a new password stays that way however often `make up` runs. To
    # restore it, use the staff interface or `make manage ARGS="changepassword ..."`.
    print(
        f"Administrator {username!r} already exists; left unchanged "
        "(password, active and staff status are its own)."
    )
