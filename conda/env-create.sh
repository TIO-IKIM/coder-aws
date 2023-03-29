#!/usr/bin/env sh

curl -sSLO https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
	&& chmod +x Miniconda3-latest-Linux-x86_64.sh \
	&& ./Miniconda3-latest-Linux-x86_64.sh -bu \
	&& conda env create --file environment.yml --prefix /datashare/envs/mlcourse
