"""Create the stack's administrator account if it is absent; never touch an existing one.

Piped into `manage.py shell` by `make admin`, so it runs inside the web
container with Django already configured. The credentials arrive as
environment variables set on that one exec call: they are not part of the
image and not part of the service definition in docker-compose.yml.

The password is never printed: a terminal's scrollback and a CI log outlive
the moment they were needed. It is in .env, which only its owner can read.
"""

import os
import sys

from django.contrib.auth import get_user_model

username = os.environ.get("DJANGO_SUPERUSER_USERNAME", "").strip()
email = os.environ.get("DJANGO_SUPERUSER_EMAIL", "").strip()
password = os.environ.get("DJANGO_SUPERUSER_PASSWORD", "")

if not username:
    sys.stderr.write("DJANGO_SUPERUSER_USERNAME must be set in .env.\n")
    sys.exit(1)

User = get_user_model()
user = User.objects.filter(username=username).first()

if user is not None:
    # Left exactly as it is: no password reset, and no re-enabling or
    # re-promoting either. An account someone has since disabled, demoted or
    # given a new password stays that way however often `make up` runs, and
    # the password in .env is not needed, so it may be blank by now. To
    # restore the account, use `make manage ARGS="changepassword ..."`.
    print(
        f"Administrator {username!r} already exists; left unchanged "
        "(password, active and staff status are its own)."
    )
elif not password:
    sys.stderr.write(
        f"There is no administrator {username!r} yet and DJANGO_SUPERUSER_PASSWORD "
        "is blank in .env. Delete that line and run `make up` again to have "
        "one generated, or set a password of your own.\n"
    )
    sys.exit(1)
else:
    User.objects.create_superuser(username=username, email=email, password=password)
    print(f"Created administrator {username!r}. Its password is DJANGO_SUPERUSER_PASSWORD in .env.")
    print("A superuser is automatically an Admin in the staff interface.")
