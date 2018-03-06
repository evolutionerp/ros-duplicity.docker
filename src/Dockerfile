# ros-duplicity.docker
# Copyright (C) 2017  evolution.it
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

FROM alpine:latest
RUN apk --update add bash duplicity docker jq py2-pip
RUN pip2 install fasteners
COPY lib /lib
COPY bin /bin
COPY entryPoint.sh /entryPoint.sh
RUN chmod +x /entryPoint.sh /bin/*
VOLUME /cache /conf /tmp /var/run/docker.sock
ENTRYPOINT ["/entryPoint.sh"]
