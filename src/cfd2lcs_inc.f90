!********************************************************
!CFD2LCS Fortran Include file.
!Contains interface definitions needed for user-level API
!********************************************************

!
! Set the precision: (single =4, double = 8)
!
integer, parameter:: LCS_PRECISION = 4

!
!	LCSRP = REAL precision
!	LCSIP = INTEGER precision
!
integer, parameter 	:: LCSRP = LCS_PRECISION
integer, parameter 	:: LCSIP = 4

!
! The default string length for lcs labels
!
integer,parameter:: LCS_NAMELEN = 32

!
! Boundary condition flags:
!
integer(LCSIP),parameter:: &
	LCS_PERIODIC = 0, &
	LCS_INFLOW = 1, &
	LCS_OUTFLOW = 2, &
	LCS_WALL = 3, &
	LCS_SLIP = 4

!
! Define the different types of LCS diagnostics here
!
integer(LCSIP),parameter:: &
	FTLE_FWD = 0, &
	FTLE_BKWD = 1, &
	LP_TRACER = 2
