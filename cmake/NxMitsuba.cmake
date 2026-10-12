# Mitsuba as a dependency.
#
# Mitsuba is used from Python (reference renders, metrics). The C++ side only
# needs to know which interpreter to use and, if the wheel ships headers, where
# they are. Linking libmitsuba.dylib from C++ has never been exercised yet, so
# treat that part as unverified until an experiment actually needs it.

set(NX_PYTHON "" CACHE FILEPATH "Python interpreter for python-type experiments")

# nx_mitsuba_python(<out_var>) — interpreter to use, preferring the project venv.
function(nx_mitsuba_python out_var)
    if(NX_PYTHON AND EXISTS "${NX_PYTHON}")
        set(${out_var} "${NX_PYTHON}" PARENT_SCOPE)
        return()
    endif()

    foreach(_candidate IN ITEMS
            "${CMAKE_SOURCE_DIR}/.venv/bin/python3"
            "${CMAKE_SOURCE_DIR}/.venv/bin/python")
        if(EXISTS "${_candidate}")
            set(NX_PYTHON "${_candidate}" CACHE FILEPATH "Python interpreter" FORCE)
            message(STATUS "nx: python = ${_candidate} (project venv)")
            set(${out_var} "${_candidate}" PARENT_SCOPE)
            return()
        endif()
    endforeach()

    find_program(_sys_python NAMES python3)
    if(_sys_python)
        set(NX_PYTHON "${_sys_python}" CACHE FILEPATH "Python interpreter" FORCE)
        message(STATUS
            "nx: python = ${_sys_python} (no .venv yet — create one with scripts/check_env.py)")
        set(${out_var} "${_sys_python}" PARENT_SCOPE)
        return()
    endif()

    message(STATUS "nx: no python interpreter found")
    set(${out_var} "" PARENT_SCOPE)
endfunction()

# nx_mitsuba_target(<out_var>) — always yields a usable target name.
function(nx_mitsuba_target out_var)
    if(TARGET nx::mitsuba)
        set(${out_var} nx::mitsuba PARENT_SCOPE)
        return()
    endif()

    nx_mitsuba_python(_py)

    add_library(nx_mitsuba INTERFACE)
    add_library(nx::mitsuba ALIAS nx_mitsuba)

    if(_py)
        target_compile_definitions(nx_mitsuba INTERFACE NX_MITSUBA_PYTHON="${_py}")

        execute_process(
            COMMAND "${_py}" -c
                "import mitsuba, os; print(os.path.dirname(mitsuba.__file__))"
            OUTPUT_VARIABLE _mi_dir
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
            RESULT_VARIABLE _rc)

        if(_rc EQUAL 0 AND IS_DIRECTORY "${_mi_dir}")
            if(IS_DIRECTORY "${_mi_dir}/include")
                target_include_directories(nx_mitsuba INTERFACE "${_mi_dir}/include")
            endif()
            if(EXISTS "${_mi_dir}/libmitsuba.dylib")
                target_link_directories(nx_mitsuba INTERFACE "${_mi_dir}")
                target_link_libraries(nx_mitsuba INTERFACE mitsuba)
            endif()
            message(STATUS "nx: mitsuba package = ${_mi_dir}")
        else()
            message(STATUS
                "nx: mitsuba is not importable by ${_py}. Run scripts/check_env.py "
                "after creating the virtual environment.")
        endif()
    endif()

    set(${out_var} nx::mitsuba PARENT_SCOPE)
endfunction()
