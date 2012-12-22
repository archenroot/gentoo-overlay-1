# Copyright 1999-2012 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI="5"

# Mainteiner notes:
# - This ebuild uses Bundler to download and install all gems in deployment mode
#   (i.e. into isolated directory inside application). That's not Gentoo way how
#   it should be done, but GitLab has too many dependencies that it will be too
#   difficult to maintain them via ebuilds.
#

USE_RUBY="ruby19"

inherit eutils ruby-ng

MY_PN="gitlabhq"
MY_PV="${PV/_/}_cvut"
MY_P="${MY_PN}-${MY_PV}"

DESCRIPTION="GitLab is a free project and repository management application"
HOMEPAGE="https://github.com/gitlabhq/gitlabhq"
SRC_URI="https://github.com/cvut/gitlabhq/archive/v${MY_PV}.tar.gz -> ${MY_P}.tar.gz"

LICENSE="AS-IS"
SLOT="4.0"
KEYWORDS="~amd64 ~x86"
IUSE="+postgres mysql +unicorn thin development test"

## Gems dependencies:
#   charlock_holmes		dev-libs/icu
#	json				dev-util/ragel
#   yajl-ruby			dev-libs/yajl
#   execjs				net-libs/nodejs, or any other JS runtime
#   pg					dev-db/postgresql-base
#   mysql				virtual/mysql
#
GEMS_DEPEND="
	dev-libs/icu
	dev-util/ragel
	dev-libs/yajl
	net-libs/nodejs
	postgres? ( dev-db/postgresql-base )
	mysql? ( virtual/mysql )"
DEPEND="${GEMS_DEPEND}
	$(ruby_implementation_depend ruby19 '=' -1.9.3*)[readline,ssl,yaml]
	dev-libs/libxml2
	dev-libs/libxslt
	dev-python/pygments
	dev-vcs/git
	dev-vcs/gitolite[gitlab(-)]
	net-misc/curl
	virtual/ssh"
RDEPEND="${GEMS_DEPEND}
	dev-db/redis
	virtual/mta"
ruby_add_bdepend "
	virtual/rubygems
	>=dev-ruby/bundler-1.0"

RUBY_S="${MY_P}"

MY_NAME="gitlab"
MY_USER="gitlab"
DEST_DIR="/opt/${MY_NAME}-${SLOT}"
CONF_DIR="/etc/${MY_NAME}-${SLOT}"

pkg_setup() {
    enewgroup ${MY_USER}
    enewuser ${MY_USER} -1 /bin/bash ${DEST_DIR} "${MY_USER}"
}

each_ruby_prepare() {

	# fix Gitolite paths
	local gitolite_base=/var/lib/gitolite/repositories
	local gitolite_hooks=/var/lib/gitolite/.gitolite/hooks
	sed -i \
		-e "s|\(\s*base_path:\s\)/home/git.*|\1${gitolite_base}/|" \
		-e "s|\(\s*hooks_path:\s\)/home/git.*|\1${gitolite_hooks}/|" \
		config/gitlab.yml.example || die "failed to filter gitolite.yml.example"
	
	# modify database settings
	sed -i \
		-e '/database:/ a\  schema_search_path: public' \
		-e 's|gitlabhq_production|gitlab|' \
		-e 's|\(username:\) postgres.*|\1 gitlab|' \
		-e 's|\(password:\).*|\1 gitlab|' \
		-e 's|\(socket:\).*|/run/postgresql/.s.PGSQL.5432|' \
		config/database.yml.postgresql \
		|| die "failed to filter database.yml.postgresql"

	# remove needless files
	use unicorn || rm config/unicorn.rb.example
	use postgres || rm config/database.yml.postgresql
	use mysql || rm config/database.yml.mysql

	# remove zzet's stupid migration which expetcs that users are so foolish 
	# to use PostgreSQL's superuser in database.yml...
	rm db/migrate/20121009205010_postgres_create_integer_cast.rb

	# remove dependency on therubyracer and libv8 (we're using nodejs instead)
	local tfile; for tfile in Gemfile{,.lock}; do
		sed -i \
			-e '/therubyracer/d' \
			-e '/libv8/d' \
			"${tfile}" || die "failed to filter ${tfile}"
	done
}

each_ruby_install() {
	local dest=${DEST_DIR}
	local conf=/etc/${MY_NAME}-${SLOT}
	local temp=/var/tmp/${MY_NAME}-${SLOT}
	local logs=/var/log/${MY_NAME}-${SLOT}

	## Prepare directories ##

	diropts -m750
	keepdir "${logs}"
	dodir "${temp}"

	diropts -m755
	keepdir "${conf}"
	dodir "${dest}" 

	dosym "${temp}" "${dest}/tmp"
	dosym "${logs}" "${dest}/log"

	## Install configs ##

	insinto "${conf}"
	doins -r config/*
	dosym "${conf}" "${dest}/config"

	## Install all others ##

	# remove needless dirs
	rm -Rf config tmp log

	insinto "${dest}"
	doins -r ./

	## Install logrotate config ##

	dodir /etc/logrotate.d
	sed -e "s|@LOG_DIR@|${logs}|" \
		"${FILESDIR}"/gitlab.logrotate > "${D}"/etc/logrotate.d/${MY_NAME}-${SLOT} \
		|| die "failed to filter gitlab.logrotate"

	## Install gems via bundler ##

	cd "${D}/${dest}"

	local without
	local flag; for flag in development test postgres mysql thin unicorn; do
		without+="$(use $flag || echo ' '$flag)"
	done
	local bundle_args="--deployment ${without:+--without${without}}"

	einfo "Running bundle install ${bundle_args} ..."
	${RUBY} /usr/bin/bundle install ${bundle_args} || die "bundler failed"

	## Clean ##

	local gemsdir=vendor/bundle/ruby/$(ruby_rbconfig_value 'ruby_version')

	# remove gems cache
	rm -Rf ${gemsdir}/cache

	# fix permissions
	fowners -R ${MY_USER}:${MY_USER} "${dest}" "${conf}" "${temp}" "${logs}"
	fperms +x resque.sh resque_dev.sh script/rails
}

pkg_postinst() {
	if [ ! -e "${DEST_DIR}/.ssh/id_rsa" ]; then
		einfo "Generating SSH key for gitlab"
		su -l ${MY_USER} -c "
			mkdir ${DEST_DIR}/.ssh 2>/dev/null
			ssh-keygen -q -N '' -t rsa -f ${DEST_DIR}/.ssh/id_rsa" \
			|| die "failed to generate SSH key"
	fi
	if [ ! -e "${DEST_DIR}/.gitconfig" ]; then
		einfo "Setting git user"
		su -l ${MY_USER} -c "
			git config --global user.email 'gitlab@localhost';
			git config --global user.name 'Gitlab'" \
			|| die "failed to setup git name and email"
	fi
	
	elog
	elog "Copy ${CONF_DIR}/gitlab.yml.example to ${CONF_DIR}/gitlab.yml"
	elog "and edit this file in order to configure your GitLab settings."
	elog
	elog "Copy ${CONF_DIR}/database.yml.* to ${CONF_DIR}/database.yml"
	elog "and edit this file in order to configure your database settings"
	elog "for \"production\" environment."
	elog
	elog "Then you should create database for your GitLab instance."
	elog
	if use postgres; then
        elog "If you have local PostgreSQL running, just copy&run:"
        elog "    su postgres"
        elog "    psql -c \"CREATE ROLE gitlab PASSWORD 'gitlab' \\"
        elog "        NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN;\""
        elog "    createdb -E UTF-8 -O gitlab gitlab"
		elog "Note: You should change your password to something more random..."
		elog
 		elog "GitLab uses polymorphic associations which are not SQL-standard friendly."
		elog "To get it work you must use this ugly workaround:"
		elog "    psql -U postgres -d gitlab"
		elog "    CREATE CAST (integer AS text) WITH INOUT AS IMPLICIT;"
		elog
	fi
	elog "Finally execute the following command to initlize environment:"
	elog "    emerge --config \"=${CATEGORY}/${PF}\""
	elog "Note: Do not forget to start Redis server."
	elog
}

pkg_config() {
	## Check config files existence ##

	einfo "Checking configuration files"

	if [ ! -r "${CONF_DIR}/database.yml" ] ; then
		eerror "Copy ${CONF_DIR}/database.yml.* to"
		eerror "${CONF_DIR}/database.yml and edit this file in order to configure your" 
		eerror "database settings for \"production\" environment."
		die
	fi
	if [ ! -r "${CONF_DIR}/gitlab.yml" ]; then
		eerror "Copy ${CONF_DIR}/gitlab.yml.example to ${CONF_DIR}/gitlab.yml"
		eerror "and edit this file in order to configure your GitLab settings"
		eerror "for \"production\" environment."
		die
	fi

	# read Gitolite base and hooks path from gitlab.yml
	local repo_path="$(sed -n \
		-e '/^git_host:/,/^\w:/s/\s*base_path:\s*\(.*\)\s*$/\1/p' \
		${CONF_DIR}/gitlab.yml)"
	local hooks_path="$(sed -n \
		-e '/^git_host:/,/^\w:/s/\s*hooks_path:\s*\(.*\)\s*$/\1/p' \
		${CONF_DIR}/gitlab.yml)"
	local git_user="$(sed -n \
		-e '/^git_host:/,/^\w:/s/\s*git_user:\s*\(.*\)\s*$/\1/p' \
		${CONF_DIR}/gitlab.yml)"
	
	if [ -z "${hooks_path}" ] || [ -z "${repo_path}" ] || [ -z "${git_user}" ]; then
		eerror "Could not find base_path, hooks_path or git_user in your gitlab.yml"
		die
	fi

	# check if Gitolite's base_path is in its home
	local git_home=$(getent passwd ${git_user} | cut -d: -f6)
	if [ ! "$(dirname ${repo_path})" -ef "${git_home}" ]; then
		eerror "Gitolite's base_path from gitlab.yml is not in the HOME of"
		eerror "${git_user} user in passwd"; die
	fi

	# add git to gitlab group
	usermod -a -G ${git_user} ${MY_USER} \
		|| "failed to add ${git_user} to ${MY_USER} group"


	## Initialize Gitolite ##

	# if Gitolite is not initialized yet
	if [ -n "${git_home}" ]; then
		# copy GitLab's SSH key
		cp "${DEST_DIR}/.ssh/id_rsa.pub" "${git_home}/gitlab.pub" \
			|| die "failed to copy GitLab's SSH key to ${git_home}"

		einfo "Initializing Gitolite"
		su -l ${git_user} -c "
			gitolite setup -pk ${git_home}/gitlab.pub" \
			|| die "failed to initialize Gitolite"

		rm "${git_home}/gitlab.pub"
	fi
	chmod -R ug+rwXs,o-rwx "${repo_path}" \
		|| die "failed to change permissions on ${repo_path}"

	# copy git hook
	einfo "Copying git hook to ${hooks_path}"
	hooks_path+=/common
	cp ${DEST_DIR}/lib/hooks/post-receive "${hooks_path}" \
		|| die "failed to copy hook to ${hooks_path}"
	chown ${git_user}:${git_user} "${hooks_path}/post-receive" || die "failed to change perms"
	chmod 750 "${hooks_path}/post-receive" || die "failed to change perms"


	## Initialize app ##

	local RAILS_ENV=${RAILS_ENV:-production}
	local RUBY=${RUBY:-ruby19}

	einfo "Initializing database ..."
	su -l ${MY_USER} -c "
		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
		cd ${DEST_DIR}
		${RUBY} /usr/bin/bundle exec rake gitlab:app:setup RAILS_ENV=${RAILS_ENV}" \
		|| die "failed to run rake gitlab:app:setup"

# doesn't work, don't know why...
#	einfo "Checking status ..."
#	su -l ${MY_USER} -c "
#		export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8
#		cd ${DEST_DIR}
#		${RUBY} /usr/bin/bundle exec rake gitlab:env:info RAILS_ENV=${RAILS_ENV}" \
#		|| die "failed to run rake gitlab:app:status"
}