#cython: boundscheck=False
#cython: wraparound=False
#cython: cdivision=True
#cython: nonecheck=False
#cython: profile=False
#cython: infer_types=False
from __future__ import absolute_import, division

from scipy.sparse import coo_matrix
import numpy as np
cimport numpy as np

from ..logger import msg
from ..constants import ZGLOBAL
from ..utils import unitvec, area_of_polygon, getMid
from .classes import IntegrationPoint

ctypedef np.int64_t cINT
ctypedef np.double_t cDOUBLE


def calc_kC(object mesh, prop_from_node, silent=True):
    """Calculate the constitutive stiffness matrix for a given input mesh

    Parameters
    ----------

    mesh : :class:`pyNastran.bdf.BDF` object
        The object must have the proper edge references as those returned by
        :func:`.read_mesh` or :func:`.read_delaunay`

    prop_from_node : bool
        If the constitutive properties are assigned per node. Otherwise they
        are considered assigned per element

    Returns
    -------
    k0 : (N, N) array-like
        The constitutive stiffness matrix

    """
    cdef int i1, i2, i3, i4, dof, c
    cdef double Ac
    cdef double A11, A12, A16, A22, A26, A66
    cdef double B11, B12, B16, B22, B26, B66
    cdef double D11, D12, D16, D22, D26, D66
    cdef double f11, f12, f13, f14
    cdef double f21, f22, f23, f24
    cdef double f31, f32, f33, f34
    cdef double f41, f42, f43, f44
    cdef double le1, le2, le3, le4
    cdef double nx1, nx2, nx3, nx4
    cdef double ny1, ny2, ny3, ny4
    cdef np.ndarray[cINT, ndim=1] kCr, kCc
    cdef np.ndarray[cDOUBLE, ndim=1] kCv

    msg('Calculating K0...', silent=silent)
    edges = mesh.edges.values()
    for edge in edges:
        if prop_from_node:
            for node in edge.nodes:
                if node.prop is None:
                    raise ValueError('Property missing for node: %s' %
                            str(node.xyz))
        else:
            for tria in edge.trias:
                if tria.prop is None:
                    raise ValueError('Property missing for tria: %s' % str(tria.nodes))

    for edge in edges:
        if len(edge.trias) == 1:
            tria1 = edge.trias[0]
            tria2 = None
            othernode_id1 = (set(tria1.node_ids) - set(edge.node_ids)).pop()
            edge.othernode1 = mesh.nodes[othernode_id1]
            edge.othernode2 = None
            mid1 = getMid(tria1)
        elif len(edge.trias) == 2:
            tria1 = edge.trias[0]
            tria2 = edge.trias[1]
            othernode_id1 = (set(tria1.node_ids) - set(edge.node_ids)).pop()
            othernode_id2 = (set(tria2.node_ids) - set(edge.node_ids)).pop()
            edge.othernode1 = mesh.nodes[othernode_id1]
            edge.othernode2 = mesh.nodes[othernode_id2]
            mid1 = getMid(tria1)
            mid2 = getMid(tria2)
        else:
            raise NotImplementedError('ntrias != 1 or 2 for an edge')

        node1 = edge.nodes[0]
        node2 = edge.nodes[1]

        ipts = []
        sdomain = []

        # to guarantee outward normals
        if np.dot(np.cross((mid1 - node2.xyz), (node1.xyz - node2.xyz)), ZGLOBAL) < 0:
            node1, node2 = node2, node1

        tmpvec = (node1.xyz - mid1)
        nx, ny, nz = unitvec(np.cross(tmpvec, ZGLOBAL))
        sdomain.append(node1.xyz)
        sdomain.append(mid1)
        le = np.sqrt(((node1.xyz - mid1)**2).sum())
        ipt = IntegrationPoint(tria1, node1, node2, edge.othernode1, 2./3, 1./6, 1./6, nx, ny, nz, le)
        ipts.append(ipt)

        tmpvec = (mid1 - node2.xyz)
        nx, ny, nz = unitvec(np.cross(tmpvec, ZGLOBAL))
        sdomain.append(node2.xyz)
        le = np.sqrt(((mid1 - node2.xyz)**2).sum())
        ipt = IntegrationPoint(tria1, node1, node2, edge.othernode1, 1./6, 2./3, 1./6, nx, ny, nz, le)
        ipts.append(ipt)

        if tria2 is None:
            tmpvec = (node2.xyz - node1.xyz)
            nx, ny, nz = unitvec(np.cross(tmpvec, ZGLOBAL))
            sdomain.append(node1.xyz)
            le = np.sqrt(((node2.xyz - node1.xyz)**2).sum())
            ipt = IntegrationPoint(tria1, node1, node2, edge.othernode1, 1./2, 1./2, 0, nx, ny, nz, le)
            ipts.append(ipt)
        else:
            tmpvec = (node2.xyz - mid2)
            nx, ny, nz = unitvec(np.cross(tmpvec, ZGLOBAL))
            sdomain.append(mid2)
            le = np.sqrt(((node2.xyz - mid2)**2).sum())
            ipt = IntegrationPoint(tria2, node1, node2, edge.othernode2, 1./6, 2./3, 1./6, nx, ny, nz, le)
            ipts.append(ipt)

            tmpvec = (mid2 - node1.xyz)
            nx, ny, nz = unitvec(np.cross(tmpvec, ZGLOBAL))
            sdomain.append(node1.xyz)
            le = np.sqrt(((mid2 - node1.xyz)**2).sum())
            ipt = IntegrationPoint(tria2, node1, node2, edge.othernode2, 2./3, 1./6, 1./6, nx, ny, nz, le)
            ipts.append(ipt)

        sdomain = np.array(sdomain)
        edge.sdomain = sdomain
        edge.Ac = area_of_polygon(sdomain[:, 0], sdomain[:, 1])
        edge.ipts = ipts

    # ASSEMBLYING GLOBAL MATRICES

    # renumbering nodes using Liu's suggested algorithm
    # - sorting nodes from a minimum spatial position to a maximum one
    # - Node oject will carry an index that will position it in the global
    #   stiffness matrix
    nodes = mesh.nodes.values()
    nodes_xyz = np.array([n.xyz for n in nodes])
    index_ref_point = nodes_xyz.min(axis=0)

    index_dist = ((nodes_xyz - index_ref_point)**2).sum(axis=-1)
    sort_ind = np.arange(len(index_dist))
    for i, node in enumerate(np.array(list(nodes))[sort_ind]):
        node.index = i

    n = len(nodes)
    dof = 5
    size = dof * n
    alloc = 256*len(edges)
    kCr = np.zeros(alloc, dtype=np.int64)
    kCc = np.zeros(alloc, dtype=np.int64)
    kCv = np.zeros(alloc, dtype=np.float64)
    c = -1

    for edge in edges:
        tria1 = edge.trias[0]
        Ac = edge.Ac
        mid1 = getMid(tria1)
        tmp = np.array([mid1, edge.n2.xyz, edge.n1.xyz])
        Ac1 = area_of_polygon(tmp[:, 0], tmp[:, 1])
        if len(edge.trias) == 1:
            tria2 = None
            Ac2 = 0
        elif len(edge.trias) == 2:
            tria2 = edge.trias[1]
            mid2 = getMid(tria2)
            tmp = np.array([mid2, edge.n1.xyz, edge.n2.xyz])
            Ac2 = area_of_polygon(tmp[:, 0], tmp[:, 1])
        else:
            raise RuntimeError('Found %d trias for edge' % len(edge.trias))
        ipts = edge.ipts
        indices = set()
        for ipt in ipts:
            indices.add(ipt.n1.index)
            indices.add(ipt.n2.index)
            indices.add(ipt.n3.index)
        indices = sorted(list(indices))
        if len(ipts) == 3:
            indices.append(0) # fourth dummy index
        indexpos = dict([[ind, i] for i, ind in enumerate(indices)])
        i1, i2, i3, i4 = indices
        f1 = [0, 0, 0, 0]
        f2 = [0, 0, 0, 0]
        f3 = [0, 0, 0, 0]
        f4 = [0, 0, 0, 0]

        nx1 = ipts[0].nx
        ny1 = ipts[0].ny
        le1 = ipts[0].le
        f1[indexpos[ipts[0].n1.index]] = ipts[0].f1
        f1[indexpos[ipts[0].n2.index]] = ipts[0].f2
        f1[indexpos[ipts[0].n3.index]] = ipts[0].f3

        nx2 = ipts[1].nx
        ny2 = ipts[1].ny
        le2 = ipts[1].le
        f2[indexpos[ipts[1].n1.index]] = ipts[1].f1
        f2[indexpos[ipts[1].n2.index]] = ipts[1].f2
        f2[indexpos[ipts[1].n3.index]] = ipts[1].f3

        nx3 = ipts[2].nx
        ny3 = ipts[2].ny
        le3 = ipts[2].le
        f3[indexpos[ipts[2].n1.index]] = ipts[2].f1
        f3[indexpos[ipts[2].n2.index]] = ipts[2].f2
        f3[indexpos[ipts[2].n3.index]] = ipts[2].f3

        if len(ipts) == 3:
            nx4 = 0
            ny4 = 0
            le4 = 0
        else:
            nx4 = ipts[3].nx
            ny4 = ipts[3].ny
            le4 = ipts[3].le
            f4[indexpos[ipts[3].n1.index]] = ipts[3].f1
            f4[indexpos[ipts[3].n2.index]] = ipts[3].f2
            f4[indexpos[ipts[3].n3.index]] = ipts[3].f3

        f11, f12, f13, f14 = f1
        f21, f22, f23, f24 = f2
        f31, f32, f33, f34 = f3
        f41, f42, f43, f44 = f4

        if prop_from_node:
            pn1 = edge.n1.prop
            pn2 = edge.n2.prop
            po1 = edge.othernode1.prop
            if tria2 is None:
                A = 4./9*pn1.A + 4./9*pn2.A + 1./9*po1.A
                B = 4./9*pn1.B + 4./9*pn2.B + 1./9*po1.B
                D = 4./9*pn1.D + 4./9*pn2.D + 1./9*po1.D
            else:
                po2 = edge.othernode2.prop
                A = 5./12*pn1.A + 5./12*pn2.A + 1./12*po1.A + 1./12*po2.A
                B = 5./12*pn1.B + 5./12*pn2.B + 1./12*po1.B + 1./12*po2.B
                D = 5./12*pn1.D + 5./12*pn2.D + 1./12*po1.D + 1./12*po2.D
        else:
            prop1 = tria1.prop
            if tria2 is None:
                A = prop1.A
                B = prop1.B
                D = prop1.D
            else:
                prop2 = tria2.prop
                A = (Ac1*prop1.A + Ac2*prop2.A)/Ac
                B = (Ac1*prop1.B + Ac2*prop2.B)/Ac
                D = (Ac1*prop1.D + Ac2*prop2.D)/Ac

        A11 = A[0, 0]
        A12 = A[0, 1]
        A16 = A[0, 2]
        A22 = A[1, 1]
        A26 = A[1, 2]
        A66 = A[2, 2]

        B11 = B[0, 0]
        B12 = B[0, 1]
        B16 = B[0, 2]
        B22 = B[1, 1]
        B26 = B[1, 2]
        B66 = B[2, 2]

        D11 = D[0, 0]
        D12 = D[0, 1]
        D16 = D[0, 2]
        D22 = D[1, 1]
        D26 = D[1, 2]
        D66 = D[2, 2]

        # kC_sparse
        # kC_sparse_num=256
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + A66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+0
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + A66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+1
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + B66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D11*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D16*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+3
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D12*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + D66*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + B66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D12*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D16*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i1*dof+4
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D22*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D26*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D26*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + D66*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + A66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+0
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + A66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+1
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + B66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D11*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D16*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+3
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D12*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + D66*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + B66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D12*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D16*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i2*dof+4
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D22*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D26*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D26*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + D66*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + A66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+0
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + A66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+1
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + B66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D11*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D16*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+3
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D12*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + D66*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + B66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D12*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D16*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i3*dof+4
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D22*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D26*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D26*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + D66*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + A66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+0
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((A12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((A22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((A12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((A22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((A12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((A22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((A12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((A22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (A26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + A66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+1
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + B66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D11*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D16*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+3
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D12*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + D66*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i1*dof+0
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i1*dof+1
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i1*dof+3
        kCv[c] += Ac*((D12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i1*dof+4
        kCv[c] += Ac*((D22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*ny1 + f21*le2*ny2 + f31*le3*ny3 + f41*le4*ny4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f11*le1*nx1 + f21*le2*nx2 + f31*le3*nx3 + f41*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i2*dof+0
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i2*dof+1
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i2*dof+3
        kCv[c] += Ac*((D12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i2*dof+4
        kCv[c] += Ac*((D22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*ny1 + f22*le2*ny2 + f32*le3*ny3 + f42*le4*ny4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f12*le1*nx1 + f22*le2*nx2 + f32*le3*nx3 + f42*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i3*dof+0
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i3*dof+1
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i3*dof+3
        kCv[c] += Ac*((D12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i3*dof+4
        kCv[c] += Ac*((D22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*ny1 + f23*le2*ny2 + f33*le3*ny3 + f43*le4*ny4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f13*le1*nx1 + f23*le2*nx2 + f33*le3*nx3 + f43*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i4*dof+0
        kCv[c] += Ac*((B12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i4*dof+1
        kCv[c] += Ac*((B22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (B26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + B66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i4*dof+3
        kCv[c] += Ac*((D12*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D16*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac)
        c += 1
        kCr[c] = i4*dof+4
        kCc[c] = i4*dof+4
        kCv[c] += Ac*((D22*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D26*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + (D26*(f14*le1*ny1 + f24*le2*ny2 + f34*le3*ny3 + f44*le4*ny4)/Ac + D66*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)*(f14*le1*nx1 + f24*le2*nx2 + f34*le3*nx3 + f44*le4*nx4)/Ac)

    msg('finished!', silent=silent)

    kC = coo_matrix((kCv, (kCr, kCc)), shape=(size, size)).tocsr()

    return kC