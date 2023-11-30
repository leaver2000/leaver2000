# syntax=docker/dockerfile:1
# description: python development container for leveraging gpu 
# BUILD AND RUN
# docker build -t leaver/griblib -f Dockerfile.gpu . && docker run -it --rm --gpus all leaver/griblib
FROM nvidia/cuda:11.2.2-cudnn8-runtime-ubuntu20.04 as base
USER root
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash","-c"]
# extending the nvidia/cuda base image
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
    # [PROJ]: https://github.com/OSGeo/PROJ/blob/master/Dockerfile
    libgeos-3.8.0 libgdal26 \
    # [CUDA] 
    libnuma-dev \
    # [MISC]
    wget git zsh \
    && rm -rf /var/lib/apt/lists/*
# [ MINICONDA ]
WORKDIR /tmp
ARG CONDA_PREFIX=/opt/conda
ENV PATH="${CONDA_PREFIX}/bin:$PATH"
ARG MINICONDA_FILE=Miniconda3-py39_4.12.0-Linux-x86_64.sh
SHELL ["/bin/bash","-c"]
RUN wget https://repo.anaconda.com/miniconda/$MINICONDA_FILE \
    # installing miniconda to /opt/conda
    && bash $MINICONDA_FILE -b -p $CONDA_PREFIX && rm -f $MINICONDA_FILE \
    # # update the conda package
    && conda update -n base -c defaults conda \
    # && conda init bash zsh \
    && conda create -n tensorflow python=3.10 pip
SHELL ["conda", "run", "-n", "tensorflow", "/bin/bash", "-c"]
RUN python -m pip install --upgrade --no-cache-dir pip
# 
# 
# 
FROM base as builder
USER root
WORKDIR /
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash","-c"]
# adding several build tools needed to package compilation
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
    gcc   \
    g++    \
    cmake   \
    gfortran \
    build-essential \
    # PROJ: https://github.com/OSGeo/PROJ/blob/master/Dockerfile
    zlib1g-dev libsqlite3-dev sqlite3 libcurl4-gnutls-dev libtiff5-dev libsqlite3-0 libtiff5 \
    libgdal-dev libatlas-base-dev libhdf5-serial-dev\
    && rm -rf /var/lib/apt/lists/*
# 
# 
# compile ecCodes for cfgrib
FROM builder as eccodes
USER root
WORKDIR /tmp
ARG ECCODES="eccodes-2.24.2-Source" 
ARG ECCODES_DIR="/usr/include/eccodes"
# download and extract the ecCodes archive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN wget -c --progress=dot:giga \
    https://confluence.ecmwf.int/download/attachments/45757960/${ECCODES}.tar.gz  -O - | tar -xz -C . --strip-component=1 

WORKDIR /tmp/build
# install the ecCodes
RUN cmake -DCMAKE_INSTALL_PREFIX="${ECCODES_DIR}" -DENABLE_PNG=ON .. \
    && make -j$(nproc) \
    && make install
# 
# 
# cartopy has a dependency on proj 8.0.0
FROM builder as proj
USER root
WORKDIR /PROJ
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
    zlib1g-dev \
    libsqlite3-dev sqlite3 libcurl4-gnutls-dev libtiff5-dev
# download and extract the ecCodes archive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN wget -c --progress=dot:giga \
    https://github.com/OSGeo/PROJ/archive/refs/tags/9.0.1.tar.gz  -O - | tar -xz -C . --strip-component=1 

WORKDIR /PROJ/build

RUN cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    && make -j$(nproc) \
    && make install
# 
# 
# 
FROM base as rapids-ai
RUN conda create -n rapids -c rapidsai -c nvidia -c conda-forge  \
    rapids=22.06 python=3.9 cudatoolkit=11.5 \
    jupyterlab

FROM base as lunch-box
# user configuration for vscode remote container compatiblity
# append the vscode user
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# create a new user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd -s /bin/bash --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && apt-get update \
    && apt-get install -y sudo \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME \
    # clean up
    && apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

USER $USERNAME
# [ OH-MY-ZSH ] 
WORKDIR /tmp/zsh
RUN conda init zsh
COPY --chown=$USER_UID:$USER_GID bin/zsh-in-docker.sh .
RUN ./zsh-in-docker.sh -t robbyrussell 
# [ecCode Library]
ARG ECCODES_DIR="/usr/include/eccodes"
COPY --from=eccodes --chown=$USER_UID:$USER_GID $ECCODES_DIR $ECCODES_DIR
ENV ECCODES_DIR=$ECCODES_DIR
# [PROJ Library]
COPY --from=proj --chown=$USER_UID:$USER_GID /usr/share/proj/ /usr/share/proj/
COPY --from=proj --chown=$USER_UID:$USER_GID /usr/include/ /usr/include/
COPY --from=proj --chown=$USER_UID:$USER_GID /usr/bin/ /usr/bin/
COPY --from=proj --chown=$USER_UID:$USER_GID /usr/lib/ /usr/lib/
ENV PROJ_LIB="/usr/share/proj"
# [RAPIDS AI]
COPY --from=rapids-ai --chown=$USER_UID:$USER_GID /opt/conda/envs/rapids /opt/conda/envs/rapids
SHELL ["/bin/bash", "-c"]
# VIRTUAL_ENV=RAPIDS
RUN /opt/conda/envs/rapids/bin/python -m pip install --no-cache-dir \
    "cfgrib==0.9.10.1" \
    "netCDF4==1.6.0" \
    "nvector==0.7.7" \ 
    "zarr==2.12.0" \
    "xarray==2022.6.0" \
    "pint==0.19.2" \
    # 
    "requests==2.28.1" \
    "black==22.8.0" \ 
    "jupyter-black==0.3.1"

# VIRTUAL_ENV=TENSORFLOW
RUN /opt/conda/envs/tensorflow/bin/python -m pip install --no-cache-dir \
    # [ML]
    "tensorflow-gpu==2.9.1" \
    "zookeeper==1.3.3" \
    "gym==0.7.4" \
    # [dask]
    "dask==2022.7.1" \
    "dask[distributed]==2022.7.1" \
    "bokeh>=2.1.1" \
    # [cupy]
    "cupy-cuda11x==11.0.0" \
    # [data analysis]
    "numpy==1.23.1" \
    "xarray==2022.6.0" \
    "pandas==1.4.3" \
    # [plotting]
    "cartopy==0.20.3" \
    "matplotlib==3.5.2" \
    # [grib]
    "cfgrib==0.9.10.1" \
    "eccodes==1.4.2" \
    # [jupyter]
    "ipykernel==6.15.1" \
    "jupyter-black==0.3.1" \
    "jupyter-client==7.3.4" \
    "zarr" \
    "s3fs" \

    # RUN pip install "geopandas" "pyarrow"
    # [HEALTH-CHECKS]
    ENV TF_CPP_MIN_LOG_LEVEL="1"
SHELL ["conda", "run", "-n", "tensorflow", "/bin/bash", "-c"]
ENV PATH=/opt/conda/envs/tensorflow/bin:$PATH
# [CFGRIB]
RUN python -m cfgrib selfcheck
# [TENSORFLOW-GPU]
RUN python -c "import tensorflow as tf;print(tf.config.list_physical_devices('GPU'))"
RUN python -c "import tensorflow as tf;print([tf.config.experimental.get_device_details(gpu) for gpu in tf.config.list_physical_devices('GPU')])"
# [CARTOPY]
RUN python -c "import cartopy.crs as ccrs"
# #
# # 
# # 
# # 
USER root
RUN apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

USER $USERNAME
RUN echo "source activate tensorflow" >> ~/.zshrc
RUN rm -rf /tmp/zsh/
ENTRYPOINT [ "/bin/zsh" ]